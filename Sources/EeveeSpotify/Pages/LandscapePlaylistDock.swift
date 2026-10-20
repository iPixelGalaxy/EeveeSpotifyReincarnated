import EeveeSpotifyC
import UIKit

@available(iOS 26.0, *)
final class LandscapePlaylistDock {
    private(set) weak var bar: UINavigationBar?
    private weak var navigation: UINavigationController?
    private var barAlpha: CGFloat = 1
    private var barHidden = false
    private weak var menuSource: UIView?
    private weak var menuItem: UIBarButtonItem?
    private let back = LandscapePlaylistDock.button("chevron.left", label: "Back")
    private let more = LandscapePlaylistDock.button("ellipsis", label: "More options")
    var hasControls: Bool { back.superview != nil }

    private static func button(_ symbol: String, label: String) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .white
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        return button
    }

    init() {
        back.addAction(UIAction { [weak self] _ in self?.navigation?.popViewController(animated: true) }, for: .primaryActionTriggered)
        more.addAction(UIAction { [weak self] _ in self?.openMenu() }, for: .primaryActionTriggered)
    }

    private func openMenu() {
        if let source = menuSource {
            let control = (source as? UIControl) ?? source.eeveeFirst(UIControl.self)
            _ = EeveeFireTap(control ?? source)
        } else if let item = menuItem, let action = item.action {
            UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        }
    }

    func layout(_ controller: UIViewController, in window: UIWindow) {
        guard let frames = LandscapeNavigation.playlistDock(in: window),
              let navigation = controller.navigationController,
              navigation.navigationBar.window === window,
              let host = LandscapeNavigation.playerControlsHost(in: window)
                  ?? window.rootViewController?.viewIfLoaded else { return }
        let sourceBar = navigation.navigationBar
        if bar !== sourceBar { restore(); bar = sourceBar; barAlpha = sourceBar.alpha; barHidden = sourceBar.isHidden }
        self.navigation = navigation
        menuItem = sourceBar.topItem?.rightBarButtonItems?.first
        menuSource = menuItem?.customView
        // Native bar-button wrappers clip relocated children even with clipsToBounds disabled.
        // Keep their actions in place; host the visible glass controls alongside the player.
        sourceBar.alpha = 0
        sourceBar.isHidden = true
        for button in [back, more] where button.superview !== host { host.addSubview(button) }
        back.frame = host.convert(frames.back, from: window)
        more.frame = host.convert(frames.more, from: window)
        more.isEnabled = menuSource != nil || menuItem?.action != nil
    }

    func hit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard let frames = LandscapeNavigation.playlistDock(in: window) else { return nil }
        for (view, region) in [(back, frames.back), (more, frames.more)] {
            if let hit = NativeHitRouter.hit(view, at: point, in: window, event: event, region: region) { return hit }
        }
        return nil
    }

    func restore() {
        bar?.alpha = barAlpha
        bar?.isHidden = barHidden
        back.removeFromSuperview(); more.removeFromSuperview()
        bar = nil; navigation = nil; menuSource = nil; menuItem = nil
    }
}
