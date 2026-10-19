import Orion
import UIKit

struct KaraokeGlobalRotationGroup: HookGroup {}

class SpotifyApplicationRotationHook: ClassHook<UIApplication> {
    typealias Group = KaraokeGlobalRotationGroup
    func supportedInterfaceOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask { .allButUpsideDown }
    @objc(setDelegate:) func setDelegate(_ delegate: AnyObject?) {
        orig.setDelegate(delegate)
        KaraokeRotation.installDelegate(delegate)
    }
}

class SpotifyControllerRotationHook: ClassHook<UIViewController> {
    typealias Group = KaraokeGlobalRotationGroup
    func viewDidLoad() {
        orig.viewDidLoad()
        KaraokeRotation.prepare(target)
    }
    func viewWillAppear(_ animated: Bool) {
        KaraokeRotation.prepare(target)
        orig.viewWillAppear(animated)
    }
}

class NativeControlWindowHitHook: ClassHook<UIWindow> {
    typealias Group = KaraokeGlobalRotationGroup
    @objc(hitTest:withEvent:) func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let native = orig.hitTest(point, with: event)
        if let hit = KaraokeOverlayPresenter.routedControlHit(at: point, in: target, event: event) { return hit }
        if #available(iOS 26.0, *) {
            if let hit = LandscapeNavigation.nativeHit(at: point, in: target, event: event) { return hit }
            if let hit = LandscapePlaylistHeader.nativeHit(at: point, in: target, event: event) { return hit }
        }
        return native
    }
}

class LandscapePlayerHitRegionHook: ClassHook<UIView> {
    typealias Group = KaraokeGlobalRotationGroup
    @objc(pointInside:withEvent:) func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if #available(iOS 26.0, *), let allowed = LandscapeNavigation.pointInside(target, point: point) { return allowed }
        if #available(iOS 26.0, *), let allowed = LandscapePlaylistHeader.pointInside(target) { return allowed }
        return orig.point(inside: point, with: event)
    }
}
