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

        init?(source: UIView, heightLimit: CGFloat) {
            let content: UIView
            if source.bounds.height > heightLimit * 0.6,
               let stack = source.eeveeFirst(UIStackView.self, where: { !$0.isHidden && $0.bounds.height > 8 && $0.bounds.height < heightLimit * 0.6 }) {
                content = stack
            } else { content = source }
            guard content.bounds.width > 1, content.bounds.height > 8, let parent = content.superview else { return nil }
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
            NSLayoutConstraint.deactivate(saved)
            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = true
        }

        func restore() {
            view.removeFromSuperview()
            guard let parent else { return }
            view.translatesAutoresizingMaskIntoConstraints = translates
            if arranged, let stack = parent as? UIStackView { stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count)) }
            else { parent.insertSubview(view, at: min(index, parent.subviews.count)) }
            view.frame = frame
            NSLayoutConstraint.activate(constraints)
            parent.setNeedsLayout()
        }
    }

    private var placements: [Unit: Placement] = [:]
    private let artwork = UIImageView()
    private var refresh: Timer?

    override init(frame: CGRect) {
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
        guard let root, window != nil, root.window === window, placements[unit]?.source !== root else { return }
        placements.removeValue(forKey: unit)?.restore()
        guard let placement = Placement(source: root, heightLimit: max(200, bounds.height)) else { return }
        placements[unit] = placement
        addSubview(placement.view)
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
        refresh?.invalidate(); refresh = nil
        for unit in Unit.allCases.reversed() { placements.removeValue(forKey: unit)?.restore() }
        removeFromSuperview()
    }
    deinit { refresh?.invalidate() }
}
