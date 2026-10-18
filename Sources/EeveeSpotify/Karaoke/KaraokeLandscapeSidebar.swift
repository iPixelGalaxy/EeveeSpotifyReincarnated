import UIKit

/// Borrow live Spotify units, retaining their actions, scrubber and accessibility.
/// Restore their exact ownership and constraints when returning to portrait.
final class KaraokeLandscapeSidebar: UIScrollView {
    enum Unit: Int, CaseIterable { case information, duration, controls }
    private final class Placement {
        weak var source: UIView?
        let view: UIView
        weak var parent: UIView?
        let index: Int
        let arranged: Bool
        let constraints: [NSLayoutConstraint]
        let translates: Bool
        let frame: CGRect
        let height: CGFloat
        let controller: UIViewController?
        weak var controllerParent: UIViewController?
        let transfersController: Bool

        init?(source: UIView, heightLimit: CGFloat, host: UIViewController) {
            let content: UIView
            if source.bounds.height > heightLimit * 0.6,
               let stack = source.eeveeFirst(UIStackView.self, where: { !$0.isHidden && $0.bounds.height > 8 && $0.bounds.height < heightLimit * 0.6 }) {
                content = stack
            } else { content = source }
            guard content.bounds.width > 1, content.bounds.height > 8, let parent = content.superview else { return nil }
            let owner = content.next as? UIViewController
            let rootOwner = owner?.viewIfLoaded === content ? owner : nil
            if let rootOwner {
                guard rootOwner.parent != nil else { return nil }
                var ancestor: UIViewController? = host
                while let current = ancestor {
                    guard current !== rootOwner else { return nil }
                    ancestor = current.parent
                }
            }
            controller = rootOwner
            controllerParent = rootOwner?.parent
            transfersController = rootOwner != nil && rootOwner?.parent !== host
            self.source = source; view = content; self.parent = parent
            arranged = (parent as? UIStackView)?.arrangedSubviews.contains(content) == true
            index = arranged ? ((parent as? UIStackView)?.arrangedSubviews.firstIndex(of: content) ?? 0) : (parent.subviews.firstIndex(of: content) ?? 0)
            frame = content.frame; height = max(32, content.bounds.height)
            translates = content.translatesAutoresizingMaskIntoConstraints
            var saved = [NSLayoutConstraint]()
            var ancestor: UIView? = parent
            while let current = ancestor {
                saved += current.constraints.filter {
                    $0.isActive && $0.identifier?.hasPrefix("UISV-") != true && (($0.firstItem as? UIView) === content || ($0.secondItem as? UIView) === content)
                }
                ancestor = current.superview
            }
            constraints = saved
            if transfersController { rootOwner?.willMove(toParent: nil) }
            NSLayoutConstraint.deactivate(saved)
            content.removeFromSuperview()
            if transfersController, let rootOwner {
                rootOwner.removeFromParent()
                host.addChild(rootOwner)
            }
            content.translatesAutoresizingMaskIntoConstraints = true
        }

        func restore() {
            if transfersController { controller?.willMove(toParent: nil) }
            view.removeFromSuperview()
            if transfersController {
                controller?.removeFromParent()
                if let controller, let controllerParent { controllerParent.addChild(controller) }
            }
            guard let parent, !transfersController || controllerParent != nil else { return }
            view.translatesAutoresizingMaskIntoConstraints = translates
            if arranged, let stack = parent as? UIStackView { stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count)) }
            else { parent.insertSubview(view, at: min(index, parent.subviews.count)) }
            view.frame = frame
            NSLayoutConstraint.activate(constraints)
            if transfersController, let controllerParent { controller?.didMove(toParent: controllerParent) }
            parent.setNeedsLayout()
        }
    }

    private var placements: [Unit: Placement] = [:]
    private weak var host: UIViewController?
    private var pending: [Unit: UIView] = [:]
    private var attachScheduled = false
    private var applying = false
    private var restored = false
    private let artwork = UIImageView()
    private var refresh: Timer?

    init(frame: CGRect, host: UIViewController) {
        self.host = host
        super.init(frame: frame)
        showsVerticalScrollIndicator = false
        delaysContentTouches = false
        contentInsetAdjustmentBehavior = .never
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 10
        artwork.isAccessibilityElement = true
        artwork.accessibilityLabel = "karaoke_album_art".localized
        if #available(iOS 15.0, *), let image = KaraokeBackgroundView.lastImage { artwork.image = image }
        else { artwork.image = UIImage(systemName: "music.note") }
        artwork.tintColor = .white
        addSubview(artwork)
        refresh = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard #available(iOS 15.0, *), let self, let image = KaraokeBackgroundView.lastImage else { return }
            if self.artwork.image !== image { self.artwork.image = image }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ root: UIView?, as unit: Unit) {
        guard !restored, !applying, let root, window != nil, root.window === window,
              placements[unit]?.source !== root else { return }
        pending[unit] = root
        guard !attachScheduled else { return }
        attachScheduled = true
        // Reparent only after Spotify's viewDidLayoutSubviews/rotation stack unwinds.
        DispatchQueue.main.async { [weak self] in self?.applyPendingUnits() }
    }

    private func applyPendingUnits() {
        attachScheduled = false
        guard !restored, let host, window != nil else { pending.removeAll(); return }
        let roots = pending
        pending.removeAll()
        applying = true
        defer { applying = false }
        for unit in Unit.allCases {
            guard let root = roots[unit], root.window === window,
                  placements[unit]?.source !== root else { continue }
            placements.removeValue(forKey: unit)?.restore()
            guard let placement = Placement(source: root, heightLimit: max(200, bounds.height), host: host) else { continue }
            placements[unit] = placement
            addSubview(placement.view)
            if placement.transfersController { placement.controller?.didMove(toParent: host) }
            writeDebugLog("[Karaoke][landscape] attached \(unit) controllerTransferred=\(placement.transfersController)")
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rows = Unit.allCases.compactMap { placements[$0] }
        let rowHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
        let side = max(80, min(bounds.width - 8, bounds.height - rowHeight - CGFloat(rows.count) * 6 - 8))
        artwork.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
        var y = side + 6
        for row in rows {
            let target = CGRect(x: 0, y: y, width: bounds.width, height: row.height)
            if row.view.frame != target { row.view.frame = target }
            y += row.height + 6
        }
        contentSize = CGSize(width: bounds.width, height: y)
    }

    func restore() {
        restored = true
        pending.removeAll()
        refresh?.invalidate(); refresh = nil
        for unit in Unit.allCases.reversed() { placements.removeValue(forKey: unit)?.restore() }
        removeFromSuperview()
    }
    deinit { refresh?.invalidate() }
}
