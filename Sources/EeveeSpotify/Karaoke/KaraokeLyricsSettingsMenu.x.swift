import Orion
import SwiftUI
import UIKit

/// Extend the existing Now Playing menu and keep its original actions.
enum KaraokeLyricsSettingsMenu {
    private static weak var header: UIView?
    private static weak var settingsController: UIViewController?
    private static let section = UIMenu.Identifier(rawValue: "com.eevee.lyrics.settings")
    private static let barItems = NSHashTable<UIBarButtonItem>.weakObjects()

    static func register(_ view: UIView) {
        header = view
        var pending = [view]
        while let current = pending.popLast() {
            pending.append(contentsOf: current.subviews)
            if let button = current as? UIButton, let menu = button.menu {
                let updated = augment(menu, source: button)
                if updated !== menu { button.menu = updated }
            }
        }
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController {
                let name = NSStringFromClass(type(of: controller))
                if name.contains("NowPlaying") {
                    for item in controller.navigationItem.rightBarButtonItems ?? [] {
                        barItems.add(item)
                        if let menu = item.menu {
                            let updated = append(to: menu)
                            if updated !== menu { item.menu = updated }
                        }
                    }
                }
            }
            responder = current.next
        }
    }

    static func augment(_ menu: UIMenu, source: UIView) -> UIMenu {
        guard let header, source.isDescendant(of: header) else { return menu }
        return append(to: menu)
    }
    static func augment(_ menu: UIMenu, item: UIBarButtonItem) -> UIMenu {
        barItems.contains(item) ? append(to: menu) : menu
    }
    static func decorateTrackMenu(_ controller: UIViewController) {
        let name = NSStringFromClass(type(of: controller))
        guard #available(iOS 15.0, *), name.contains("ContextMenu"), let header else { return }
        var sheet = controller
        while let parent = sheet.parent { sheet = parent }
        let fromPlayer = sheet.presentingViewController.map { NSStringFromClass(type(of: $0)).contains("NowPlaying") } ?? false
        let headerVisible = header.window.map { header.convert(header.bounds, to: $0).intersects($0.bounds) } ?? false
        guard fromPlayer || headerVisible else { return }
        let bundle = Bundle(for: type(of: controller))
        guard bundle == Bundle.main || bundle.bundlePath.hasPrefix(Bundle.main.bundlePath + "/Frameworks/") else { return }
        guard let root = controller.viewIfLoaded else { return }
        var pending = [root]
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            guard let table = view as? UITableView else { continue }
            guard !(table.tableHeaderView is KaraokeTrackMenuHeader) else { continue }
            guard table.bounds.width > 0 else { continue }
            let original = table.tableHeaderView
            table.tableHeaderView = nil
            let row = KaraokeTrackMenuHeader(original: original, width: table.bounds.width) { [weak table] in
                guard let table else { return }
                openFromTrackMenu(table)
            }
            table.tableHeaderView = row
            eeveeLog("[Karaoke] Added Lyrics Settings to %@", name)
            return
        }
    }

    private static func openFromTrackMenu(_ view: UIView) {
        var responder: UIResponder? = view
        var owner: UIViewController?
        while let current = responder {
            if let controller = current as? UIViewController { owner = controller; break }
            responder = current.next
        }
        guard var sheet = owner else { return }
        while let parent = sheet.parent { sheet = parent }
        guard let presenter = sheet.presentingViewController else { return }
        sheet.dismiss(animated: true) { showSettings(from: presenter) }
    }

    private static func append(to menu: UIMenu) -> UIMenu {
        guard !menu.children.contains(where: { ($0 as? UIMenu)?.identifier == section }) else { return menu }
        let action = UIAction(title: "karaoke_settings".localized, image: UIImage(systemName: "slider.horizontal.3")) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { presentSettings(attempts: 8) }
        }
        return menu.replacingChildren(menu.children + [UIMenu(title: "", identifier: section, options: .displayInline, children: [action])])
    }
    private static func presentSettings(attempts: Int) {
        guard settingsController == nil, let header, header.window != nil else { return }
        var responder: UIResponder? = header
        var owner: UIViewController?
        while let current = responder {
            if let controller = current as? UIViewController { owner = controller; break }
            responder = current.next
        }
        guard var presenter = owner else { return }
        while let parent = presenter.parent { presenter = parent }
        while let presented = presenter.presentedViewController {
            if presented.isBeingDismissed || NSStringFromClass(type(of: presented)).contains("ContextMenu") {
                if attempts > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { presentSettings(attempts: attempts - 1) }
                }
                return
            }
            presenter = presented
        }
        guard !presenter.isBeingDismissed else { return }
        showSettings(from: presenter)
    }

    private static func showSettings(from presenter: UIViewController) {
        guard settingsController == nil else { return }
        KaraokeOverlayPresenter.interact()
        let controller = UIHostingController(rootView: KaraokeQuickSettingsPage {
            settingsController?.dismiss(animated: true)
        })
        controller.modalPresentationStyle = .fullScreen
        controller.overrideUserInterfaceStyle = .dark
        settingsController = controller
        presenter.present(controller, animated: true)
    }
}

private struct KaraokeQuickSettingsPage: View {
    let onBack: () -> Void
    var body: some View {
        NavigationView {
            EeveeLyricsSettingsView()
                .navigationTitle("karaoke_settings".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("karaoke_back".localized, action: onBack)
                            .accessibilityLabel("karaoke_back_to_lyrics".localized)
                    }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accessibilityAction(.escape, onBack)
    }
}

class KaraokeLyricsButtonMenuHook: ClassHook<UIButton> {
    typealias Group = KaraokeFooterGroup
    func setMenu(_ menu: UIMenu?) {
        orig.setMenu(menu.map { KaraokeLyricsSettingsMenu.augment($0, source: target) })
    }
}

class KaraokeLyricsBarMenuHook: ClassHook<UIBarButtonItem> {
    typealias Group = KaraokeFooterGroup
    func setMenu(_ menu: UIMenu?) {
        orig.setMenu(menu.map { KaraokeLyricsSettingsMenu.augment($0, item: target) })
    }
}

@available(iOS 15.0, *)
private final class KaraokeTrackMenuHeader: UIView {
    private let original: UIView?
    private let originalHeight: CGFloat
    private let button = UIButton(type: .system)
    private let rowHeight = max(52, UIFont.preferredFont(forTextStyle: .body).lineHeight + 24)
    init(original: UIView?, width: CGFloat, action: @escaping () -> Void) {
        self.original = original
        originalHeight = original?.bounds.height ?? 0
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: originalHeight + rowHeight))
        autoresizingMask = .flexibleWidth
        if let original { original.translatesAutoresizingMaskIntoConstraints = true; addSubview(original) }
        var configuration = UIButton.Configuration.plain()
        configuration.title = "karaoke_settings".localized
        configuration.image = UIImage(systemName: "slider.horizontal.3")
        configuration.imagePadding = 14
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: originalHeight + rowHeight) }
    override func layoutSubviews() {
        super.layoutSubviews()
        original?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: originalHeight)
        button.frame = CGRect(x: 0, y: originalHeight, width: bounds.width, height: rowHeight)
    }
}

class KaraokeTrackMenuPresentationHook: ClassHook<UIViewController> {
    typealias Group = KaraokeFooterGroup
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        if NSStringFromClass(type(of: target)).contains("ContextMenu") {
            DispatchQueue.main.async { [weak target] in
                if let target { KaraokeLyricsSettingsMenu.decorateTrackMenu(target) }
            }
        }
    }
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if NSStringFromClass(type(of: target)).contains("ContextMenu") {
            DispatchQueue.main.async { [weak target] in
                if let target { KaraokeLyricsSettingsMenu.decorateTrackMenu(target) }
            }
        }
    }
}
