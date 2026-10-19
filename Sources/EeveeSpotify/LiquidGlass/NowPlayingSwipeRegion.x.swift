import Orion
import UIKit

private enum NowPlayingSwipeRegion {
    private static var allowedKey: UInt8 = 0

    static func accepts(_ gesture: UIPanGestureRecognizer) -> Bool {
        guard #available(iOS 26.0, *), let window = gesture.view?.window else { return false }
        if gesture.state == .began || objc_getAssociatedObject(gesture, &allowedKey) == nil {
            let location = gesture.location(in: window)
            let translation = gesture.translation(in: window)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            let allowed = LandscapeNavigation.swipeStartRegion(in: window).contains(start)
            objc_setAssociatedObject(gesture, &allowedKey, allowed, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let allowed = objc_getAssociatedObject(gesture, &allowedKey) as? Bool ?? false
        if [.ended, .cancelled, .failed].contains(gesture.state) {
            objc_setAssociatedObject(gesture, &allowedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return allowed
    }
}

// This coordinator also listens to the playlist's scroll pan. Limit only presentation, preserving list scrolling
// and the fullscreen player's separate dismiss gesture.
class NowPlayingSwipeRegionHook: ClassHook<NSObject> {
    typealias Group = GlassNowPlayingBarGroup
    static let targetName = "_TtC19MainUI_TabBarUIImpl25CompactGestureCoordinator"

    @objc(handlePresentPan:) func handlePresentPan(_ gesture: UIPanGestureRecognizer) {
        guard NowPlayingSwipeRegion.accepts(gesture) else { return }
        orig.handlePresentPan(gesture)
    }

    @objc(scrollPanAction:) func scrollPanAction(_ gesture: UIPanGestureRecognizer) {
        guard NowPlayingSwipeRegion.accepts(gesture) else { return }
        orig.scrollPanAction(gesture)
    }
}
