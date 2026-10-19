import UIKit

@available(iOS 26.0, *)
final class LandscapePlaylistDock {
    private(set) weak var bar: UINavigationBar?
    var hasControls: Bool { back?.view != nil || more?.view != nil }
    private var back: NativeViewPlacement?
    private var more: NativeViewPlacement?
    private struct Saved { weak var view: UIView?; let alpha: CGFloat; let clips: Bool }
    private var saved: [ObjectIdentifier: Saved] = [:]

    private func remember(_ view: UIView) {
        let key = ObjectIdentifier(view)
        if saved[key]?.view !== view { saved[key] = Saved(view: view, alpha: view.alpha, clips: view.clipsToBounds) }
    }

    func layout(_ controller: UIViewController, in window: UIWindow) {
        guard let frames = LandscapeNavigation.playlistDock(in: window),
              let navigation = controller.navigationController?.navigationBar,
              navigation.window === window, !navigation.isHidden else { return }
        if bar !== navigation { restore(); bar = navigation }
        if back?.view?.isDescendant(of: navigation) != true || more?.view?.isDescendant(of: navigation) != true {
            let controls = GlassPlaylist.collect(UIControl.self, in: navigation).filter {
                !$0.isHidden && $0.bounds.width >= 24 && $0.bounds.height >= 24 && $0.bounds.width < window.bounds.width * 0.3
            }.sorted { $0.convert($0.bounds, to: window).midX < $1.convert($1.bounds, to: window).midX }
            if let first = controls.first, first.convert(first.bounds, to: navigation).midX < navigation.bounds.midX,
               back?.view !== first { back?.restore(); back = NativeViewPlacement(first) }
            if let last = controls.last, last !== back?.view,
               last.convert(last.bounds, to: navigation).midX > navigation.bounds.midX,
               more?.view !== last { more?.restore(); more = NativeViewPlacement(last) }
        }
        let kept = [back?.view, more?.view].compactMap { $0 }
        guard !kept.isEmpty else { return }
        func clear(_ view: UIView) {
            guard !kept.contains(where: { $0 === view }) else { return }
            remember(view)
            if kept.contains(where: { $0.isDescendant(of: view) }) {
                view.clipsToBounds = false
                view.subviews.forEach(clear)
            } else { view.alpha = 0 }
        }
        remember(navigation); navigation.clipsToBounds = false
        navigation.subviews.forEach(clear)
        back?.place(frames.back, in: window)
        more?.place(frames.more, in: window)
    }

    func hit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard let frames = LandscapeNavigation.playlistDock(in: window) else { return nil }
        for (placement, region) in [(back, frames.back), (more, frames.more)] {
            if let view = placement?.view,
               let hit = NativeHitRouter.hit(view, at: point, in: window, event: event, region: region) { return hit }
        }
        return nil
    }

    func restore() {
        back?.restore(); more?.restore(); back = nil; more = nil
        for state in saved.values { state.view?.alpha = state.alpha; state.view?.clipsToBounds = state.clips }
        saved.removeAll(); bar = nil
    }
}
