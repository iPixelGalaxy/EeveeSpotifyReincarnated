import UIKit

@available(iOS 26.0, *)
enum LandscapePlaylistInsets {
    private static var key: UInt8 = 0
    private final class State {
        var native: UIEdgeInsets
        var active = false
        var applying = false
        let indicators: UIEdgeInsets
        init(_ inset: UIEdgeInsets, indicators: UIEdgeInsets) { native = inset; self.indicators = indicators }
    }
    private static func state(_ scroll: UIScrollView) -> State {
        if let state = objc_getAssociatedObject(scroll, &key) as? State { return state }
        let state = State(scroll.contentInset, indicators: scroll.verticalScrollIndicatorInsets)
        objc_setAssociatedObject(scroll, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    static func effective(_ proposed: UIEdgeInsets, in scroll: UIScrollView) -> UIEdgeInsets {
        let state = state(scroll)
        if !state.applying { state.native = proposed }
        guard state.active, LandscapePlaylistHeader.isLandscape(scroll) else { return proposed }
        var inset = proposed; inset.top = 0
        return inset
    }

    // Called once on entry, from the next main-loop turn, never from the collection's layout callback.
    static func prepare(_ scroll: UIScrollView) {
        guard LandscapePlaylistHeader.isLandscape(scroll) else { return }
        let state = state(scroll)
        state.active = true; state.applying = true
        defer { state.applying = false }
        var inset = scroll.contentInset; inset.top = 0
        if scroll.contentInset != inset { scroll.contentInset = inset }
        var indicators = scroll.verticalScrollIndicatorInsets; indicators.top = 0
        if scroll.verticalScrollIndicatorInsets != indicators { scroll.verticalScrollIndicatorInsets = indicators }
        if scroll.contentOffset.y < 0 { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: 0), animated: false) }
        (scroll as? UICollectionView)?.collectionViewLayout.invalidateLayout()
    }

    static func restore(_ scroll: UIScrollView) {
        guard let state = objc_getAssociatedObject(scroll, &key) as? State else { return }
        state.active = false; state.applying = true
        if scroll.contentInset != state.native { scroll.contentInset = state.native }
        if scroll.verticalScrollIndicatorInsets != state.indicators { scroll.verticalScrollIndicatorInsets = state.indicators }
        state.applying = false
    }
}
