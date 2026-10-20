import UIKit

enum NativeHitRouter {
    static func hit(_ root: UIView, at point: CGPoint, in window: UIWindow, event: UIEvent?, region: CGRect? = nil) -> UIView? {
        guard root.window === window, !root.isHidden, root.alpha > 0.01, root.isUserInteractionEnabled else { return nil }
        var ancestor = root.superview
        while let view = ancestor, view !== window {
            if view.isHidden || view.alpha <= 0.01 { return nil }
            ancestor = view.superview
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard let visible = top?.viewIfLoaded, root.isDescendant(of: visible) else { return nil }
        if let region, !region.contains(point) { return nil }
        let local = root.convert(point, from: window)
        guard root.bounds.contains(local) else { return nil }
        if let hit = root.hitTest(local, with: event), hit.isDescendant(of: root),
           hit !== root || root is UIControl || root.gestureRecognizers?.isEmpty == false { return hit }
        // A native container can reject a moved child even though the child is visible.
        for child in root.subviews.reversed() {
            if let hit = child.hitTest(child.convert(local, from: root), with: event), hit.isDescendant(of: root) { return hit }
        }
        return nil
    }
}

/// Change a native view's layout without changing its view/controller ownership.
final class NativeViewPlacement {
    weak var view: UIView?
    private weak var parent: UIView?
    private let center: CGPoint
    private let bounds: CGRect
    private let transform: CGAffineTransform
    private let translates: Bool
    private let arrangedIndex: Int?
    private let constraints: [NSLayoutConstraint]

    init(_ view: UIView) {
        self.view = view; parent = view.superview
        center = view.center; bounds = view.bounds; transform = view.transform
        translates = view.translatesAutoresizingMaskIntoConstraints
        arrangedIndex = (view.superview as? UIStackView)?.arrangedSubviews.firstIndex(of: view)
        func refers(_ item: Any?) -> Bool {
            (item as? UIView) === view || (item as? UILayoutGuide)?.owningView === view
        }
        var saved = view.constraints.filter { $0.isActive && refers($0.firstItem) && ($0.secondItem == nil || refers($0.secondItem)) }
        var ancestor = view.superview
        while let current = ancestor {
            saved += current.constraints.filter {
                $0.isActive && $0.identifier?.hasPrefix("UISV-") != true && (refers($0.firstItem) || refers($0.secondItem))
            }
            ancestor = current.superview
        }
        constraints = saved
        NSLayoutConstraint.deactivate(saved)
        if arrangedIndex != nil { (view.superview as? UIStackView)?.removeArrangedSubview(view) }
        view.translatesAutoresizingMaskIntoConstraints = true
    }

    var originalHeight: CGFloat { bounds.height }

    func place(_ rect: CGRect, in coordinateView: UIView, scale: CGFloat = 1) {
        guard let view, let parent = view.superview else { return }
        let target = parent.convert(rect, from: coordinateView)
        let nextTransform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        if view.transform != nextTransform { view.transform = nextTransform }
        let size = CGSize(width: target.width / scale, height: target.height / scale)
        if view.bounds.size != size { view.bounds.size = size; view.setNeedsLayout() }
        let center = CGPoint(x: target.midX, y: target.midY)
        if view.center != center { view.center = center }
    }

    func restore() {
        guard let view else { return }
        view.transform = transform; view.bounds = bounds; view.center = center
        view.translatesAutoresizingMaskIntoConstraints = translates
        guard let parent, view.superview === parent else { return }
        if let index = arrangedIndex, let stack = parent as? UIStackView, !stack.arrangedSubviews.contains(view) {
            stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        }
        NSLayoutConstraint.activate(constraints)
        parent.setNeedsLayout()
    }
}
