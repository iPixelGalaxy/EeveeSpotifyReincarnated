import UIKit

@available(iOS 26.0, *)
enum LandscapeNavigation {
    private static weak var stock: UIView?
    private static weak var bar: GlassSystemTabBar?
    private static weak var playerHost: UIView?
    private static weak var playerCard: UIView?
    private static var player: NativeViewPlacement?
    private static var rail: LandscapeNavigationRail?
    private static var updating = false
    private static weak var insetOwner: UIViewController?
    private static var originalRightInset: CGFloat = 0
    private struct ClipState { weak var view: UIView?; let clips: Bool }
    private static var clipping: [ObjectIdentifier: ClipState] = [:]

    private static func frames(_ window: UIWindow) -> (rail: CGRect, player: CGRect)? {
        guard window.bounds.width > window.bounds.height else { return nil }
        let safe = window.safeAreaLayoutGuide.layoutFrame
        let player = CGRect(x: 16, y: safe.maxY - 66, width: window.bounds.width - 32, height: 64)
        let top = safe.minY + 64
        let bottom = player.minY - 12
        let count = max(1, bar?.items?.count ?? 4)
        let height = min(CGFloat(count * 60 + 8), max(56, bottom - top))
        let rail = CGRect(x: safe.maxX - 84, y: top + (bottom - top - height) / 2, width: 76, height: height)
        return (rail, player)
    }

    private static func overflow(_ root: UIView) {
        var current: UIView? = root
        while let view = current, !(view is UIWindow) {
            let key = ObjectIdentifier(view)
            if clipping[key]?.view !== view { clipping[key] = ClipState(view: view, clips: view.clipsToBounds) }
            if view.clipsToBounds { view.clipsToBounds = false }
            current = view.superview
        }
    }

    static func barFrame(in stock: UIView, fallback: CGRect) -> CGRect {
        self.stock = stock
        if let window = stock.window, frames(window) == nil { restore() }
        return fallback
    }

    static func didLayoutBar(_ bar: UIView, in stock: UIView) {
        guard let bar = bar as? GlassSystemTabBar, let window = stock.window else { return }
        self.stock = stock; self.bar = bar
        guard let layout = frames(window), let owner = window.rootViewController,
              let host = owner.viewIfLoaded else { restore(); return }
        if insetOwner !== owner {
            restoreContentInset()
            insetOwner = owner; originalRightInset = owner.additionalSafeAreaInsets.right
        }
        var insets = owner.additionalSafeAreaInsets
        let right = originalRightInset + window.safeAreaLayoutGuide.layoutFrame.maxX - layout.rail.minX + 12
        if abs(insets.right - right) > 0.5 { insets.right = right; owner.additionalSafeAreaInsets = insets }
        // Keep the model and its existing navigation actions; display them in a bounded rail.
        bar.layer.removeAllAnimations(); bar.alpha = 0; bar.isUserInteractionEnabled = false
        let rail = self.rail ?? LandscapeNavigationRail(frame: .zero)
        self.rail = rail
        if rail.superview !== host { host.addSubview(rail) }
        rail.frame = host.convert(layout.rail, from: window)
        rail.update(bar)
        if let playerHost, let playerCard { layoutPlayer(in: playerHost, card: playerCard) }
    }

    static func layoutPlayer(in host: UIView, card: UIView) {
        playerHost = host; playerCard = card
        guard !updating else { return }
        guard let window = host.window, let layout = frames(window) else {
            if let window = host.window, window.bounds.width <= window.bounds.height { restore() }
            return
        }
        updating = true; defer { updating = false }
        // Never relocate the fullscreen passthrough controller or its gesture surface.
        if player?.view !== card {
            player?.restore(); player = NativeViewPlacement(card)
            eeveeLog("[Landscape][Dock] bounded playback card; vertical navigation")
        }
        if let player {
            let scale = min(1, layout.player.height / max(1, player.originalHeight))
            player.place(layout.player, in: window, scale: scale)
        }
        if let parent = card.superview { overflow(parent) }
        card.layoutIfNeeded()
    }

    private static func restoreContentInset() {
        if let owner = insetOwner {
            var insets = owner.additionalSafeAreaInsets
            insets.right = originalRightInset
            owner.additionalSafeAreaInsets = insets
        }
        insetOwner = nil
    }

    private static func restore() {
        restoreContentInset()
        player?.restore(); player = nil
        rail?.removeFromSuperview(); rail = nil
        bar?.alpha = 1; bar?.isUserInteractionEnabled = true
        let saved = clipping; clipping.removeAll()
        for state in saved.values { state.view?.clipsToBounds = state.clips }
    }

    static func contentBottom(in window: UIWindow) -> CGFloat {
        (frames(window)?.player.minY ?? window.safeAreaLayoutGuide.layoutFrame.maxY - 64) - 12
    }

    static func contentRight(in window: UIWindow) -> CGFloat {
        (frames(window)?.rail.minX ?? window.safeAreaLayoutGuide.layoutFrame.maxX) - 12
    }

    static func pointInside(_ view: UIView, point: CGPoint) -> Bool? {
        guard let window = view.window, let layout = frames(window) else { return nil }
        let inside = layout.player.contains(view.convert(point, to: window))
        if view === stock { return playerCard?.isDescendant(of: view) == true ? inside : false }
        if view === playerHost { return inside }
        // Extend ancestor hit testing only at the visible card, never across page content.
        if inside, playerCard?.isDescendant(of: view) == true { return true }
        return nil
    }

    static func nativeHit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard let layout = frames(window) else { return nil }
        if let rail, layout.rail.contains(point),
           let hit = NativeHitRouter.hit(rail, at: point, in: window, event: event, region: layout.rail) { return hit }
        if let card = playerCard, layout.player.contains(point) {
            return NativeHitRouter.hit(card, at: point, in: window, event: event, region: layout.player)
        }
        return nil
    }
}
