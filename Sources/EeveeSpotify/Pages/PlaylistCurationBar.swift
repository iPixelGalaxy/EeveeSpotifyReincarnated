import EeveeSpotifyC
import UIKit

@available(iOS 26.0, *)
final class PlaylistCurationBar: UIView {
    enum Action: Int, CaseIterable {
        case add, mix, edit, sort, details
        var symbol: String {
            switch self {
            case .add: return "plus"
            case .mix: return "slider.horizontal.3"
            case .edit: return "pencil"
            case .sort: return "arrow.up.arrow.down"
            case .details: return "square.and.pencil"
            }
        }
        static func matching(_ text: String) -> Action? {
            let text = text.lowercased()
            if text.contains("details") || text.contains("name") { return .details }
            if text.contains("mix") { return .mix }
            if text.contains("edit") { return .edit }
            if text.contains("sort") { return .sort }
            if text.contains("add") { return .add }
            return nil
        }
    }
    private struct Binding {
        let source: UIView
        // A recycled native toolbar must not discard the targets used by the visible proxies.
        let targets: [AnyObject]
    }
    private var bindings = [Action: Binding]()
    private var buttons = [Action: UIButton]()
    private static let primaryClass = NSClassFromString(PlaylistChipHook.targetName)
    private(set) weak var toolbar: UIView?
    private var toolbarAlpha: CGFloat = 1
    private var toolbarInteraction = true
    private var toolbarAccessibility = false
    var compact = false
    var hasAdd: Bool { bindings[.add] != nil }
    var hasSecondaryActions: Bool { bindings.keys.contains { $0 != .add } }
    var hasActions: Bool { !bindings.isEmpty }
    var compactAddButton: UIButton? { hasAdd ? buttons[.add] : nil }
    var compactSecondaryButtons: [UIButton] {
        Action.allCases.filter { $0 != .add && bindings[$0] != nil }.compactMap { buttons[$0] }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for action in Action.allCases {
            var configuration = UIButton.Configuration.glass()
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .white
            configuration.image = UIImage(systemName: action.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            let button = UIButton(configuration: configuration)
            button.isHidden = true
            button.addAction(UIAction { [weak self] _ in self?.forward(action) }, for: .primaryActionTriggered)
            addSubview(button)
            buttons[action] = button
        }
    }
    required init?(coder: NSCoder) { nil }

    func bind(_ toolbar: UIView) {
        guard let primaryClass = Self.primaryClass else { return }
        var candidates = [UIView]()
        var queue = toolbar.subviews
        var index = 0
        while index < queue.count {
            let view = queue[index]; index += 1
            if view.isKind(of: primaryClass) { candidates.append(view) }
            else { queue += view.subviews }
        }
        var found = [Action: Binding]()
        for source in candidates {
            let title = source.accessibilityLabel ?? GlassPlaylist.collect(UILabel.self, in: source).compactMap { $0.text }.joined(separator: " ")
            guard let action = Action.matching((source.accessibilityIdentifier ?? "") + " " + title) else { continue }
            let controls = (source as? UIControl).map { [$0] } ?? GlassPlaylist.collect(UIControl.self, in: source)
            found[action] = Binding(source: source, targets: controls.flatMap { $0.allTargets.map { $0.base as AnyObject } })
            let button = buttons[action]!
            button.accessibilityLabel = title
            button.isEnabled = controls.first?.isEnabled ?? true
            if let native = controls.compactMap({ $0 as? UIButton }).first {
                button.menu = native.menu
                button.showsMenuAsPrimaryAction = native.showsMenuAsPrimaryAction
            }
        }
        guard !found.isEmpty else { return }
        if self.toolbar !== toolbar {
            restoreToolbar()
            self.toolbar = toolbar
            toolbarAlpha = toolbar.alpha
            toolbarInteraction = toolbar.isUserInteractionEnabled
            toolbarAccessibility = toolbar.accessibilityElementsHidden
            eeveeLog("[Glass][Playlist] Bound %d curation icons", found.count)
        }
        let changed = Set(bindings.keys) != Set(found.keys)
        bindings = found
        for (action, button) in buttons { button.isHidden = bindings[action] == nil }
        toolbar.alpha = 0
        toolbar.isUserInteractionEnabled = false
        toolbar.accessibilityElementsHidden = true
        if changed { setNeedsLayout(); superview?.setNeedsLayout() }
    }

    private func restoreToolbar() {
        toolbar?.alpha = toolbarAlpha
        toolbar?.isUserInteractionEnabled = toolbarInteraction
        toolbar?.accessibilityElementsHidden = toolbarAccessibility
    }

    func suspend() {
        restoreToolbar()
        toolbar = nil
        bindings.removeAll()
        removeFromSuperview()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The action row lays every compact control into one shared grid.
        guard !compact else { return }
        let actions = Action.allCases.filter { bindings[$0] != nil && (!compact || $0 != .add) }
        let side: CGFloat = 44
        let gap = max(0, min(8, (bounds.width - CGFloat(actions.count) * side) / CGFloat(max(1, actions.count - 1))))
        var x = max(0, (bounds.width - CGFloat(actions.count) * side - CGFloat(max(0, actions.count - 1)) * gap) / 2)
        for action in actions {
            buttons[action]?.frame = CGRect(x: x, y: 0, width: side, height: side)
            x += side + gap
        }
    }

    private func forward(_ action: Action) {
        guard let source = bindings[action]?.source else { return }
        let control = (source as? UIControl) ?? source.eeveeFirst(UIControl.self)
        let fired = EeveeFireTap(source) || control.map { EeveeFireTap($0) } == true
        if !fired { eeveeLog("[Glass][Playlist] Curation action %d failed", action.rawValue) }
    }
}

@available(iOS 26.0, *)
enum PlaylistChips {
    private static var toolbarKey: UInt8 = 0
    private static var layoutKey: UInt8 = 0
    static let toolbarID = "PlaylistCuration.Row.CurationActionsToolbar"

    static func toolbar(in root: UIView) -> UIView? {
        PageLookup.cached(&toolbarKey, in: root) { PageLookup.find(toolbarID, in: root) }
    }

    static func bind(in root: UIView, row: PlaylistActionRow) {
        guard let toolbar = toolbar(in: root) else { return }
        row.curation.bind(toolbar)
        row.placeCuration()
        let compact = row.compactLayout && row.curation.hasActions
        if (objc_getAssociatedObject(toolbar, &layoutKey) as? Bool) != compact {
            objc_setAssociatedObject(toolbar, &layoutKey, compact, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            var ancestor = toolbar.superview
            while let view = ancestor {
                if let collection = view as? UICollectionView {
                    DispatchQueue.main.async { [weak collection] in collection?.collectionViewLayout.invalidateLayout() }
                    break
                }
                ancestor = view.superview
            }
        }
    }

    static func style(_ button: UIView) {
        guard let toolbar = PageLookup.ancestor(of: button, id: toolbarID), let row = GlassPlaylist.row(near: toolbar) else { return }
        row.curation.bind(toolbar)
        row.placeCuration()
    }
}
