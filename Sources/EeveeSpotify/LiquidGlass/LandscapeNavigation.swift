import Orion
import UIKit

@available(iOS 26.0, *)
enum LandscapeNavigation {
    private static weak var stock: UIView?
    private static weak var bar: GlassSystemTabBar?
    private static weak var playerHost: UIView?
    private static weak var playerCard: UIView?
    private static var player: NativeViewPlacement?
    private static var rail: LandscapeNavigationRail?
    private static weak var playlist: UIView?
    private static var lastWindowSize: CGSize?
    private static weak var surface: UIView?
    private static var surfaceRadius: CGFloat = 0
    private static var surfaceClips = false
    private static var updating = false
    private static weak var insetOwner: UIViewController?
    private static var originalRightInset: CGFloat = 0
    private struct ClipState { weak var view: UIView?; let clips: Bool }
    private static var clipping: [ObjectIdentifier: ClipState] = [:]

    private static func frames(_ window: UIWindow) -> (rail: CGRect, player: CGRect)? {
        guard window.bounds.width > window.bounds.height else { return nil }
        let safe = window.safeAreaLayoutGuide.layoutFrame
        let gap = max(8, (window.safeAreaInsets.right + 8) / 2)
        let nativeHeight = min(84, max(56, bar?.bounds.height ?? 76))
        let width = nativeHeight * 1.5 * 0.8
        let count = max(1, bar?.items?.count ?? 4)
        let height = min(window.bounds.height - 16, CGFloat(count) * nativeHeight + CGFloat(count - 1) * 4 + 12)
        let rail = CGRect(x: window.bounds.maxX - gap - width, y: (window.bounds.height - height) / 2, width: width, height: height)
        let dockRight = rail.minX - 12
        let inPlaylist = playlist?.window === window
        let left: CGFloat = inPlaylist ? 72 : 24
        let right = dockRight - (inPlaylist ? 56 : 0)
        let player = CGRect(x: left, y: safe.maxY - 50, width: max(140, right - left), height: 48)
        return (rail, player)
    }

    static func layoutContentSurface(in host: UIView) {
        guard let window = host.window,
              let canvas = host.subviews.first(where: {
                  $0.bounds.width >= host.bounds.width * 0.8 && $0.bounds.height >= host.bounds.height * 0.8
              }) else { return }
        if window.bounds.width > window.bounds.height {
            guard canvas.transform.isIdentity else { return }
            if surface !== canvas {
                surface?.layer.cornerRadius = surfaceRadius
                surface = canvas; surfaceRadius = canvas.layer.cornerRadius
                surfaceClips = canvas.clipsToBounds
            }
            // Expand Spotify's inset canvas, retaining UIKit's root geometry and native constraints.
            let frame = host.convert(window.bounds, from: window)
            if canvas.frame != frame { canvas.frame = frame }
            canvas.layer.cornerRadius = 0
            canvas.clipsToBounds = false
        } else if surface === canvas {
            canvas.layer.cornerRadius = surfaceRadius
            canvas.clipsToBounds = surfaceClips
            surface = nil
        }
    }

    static func setPlaylist(_ root: UIView, visible: Bool) {
        let changed = visible ? playlist !== root : playlist === root
        if visible { playlist = root }
        else if playlist === root { playlist = nil }
        guard changed else { return }
        if let playerHost, let playerCard { layoutPlayer(in: playerHost, card: playerCard) }
        GlassNowPlayingBar.refreshLayout()
    }

    static func playlistDock(in window: UIWindow) -> (back: CGRect, more: CGRect)? {
        guard playlist?.window === window, let layout = frames(window) else { return nil }
        return (CGRect(x: 16, y: layout.player.minY, width: 48, height: 48),
                CGRect(x: layout.player.maxX + 8, y: layout.player.minY, width: 48, height: 48))
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
        // UIKit owns the window root's frame, transform and constraints during rotation.
        // Only the bounded player and navigation rail receive custom placement.
        if lastWindowSize != window.bounds.size {
            lastWindowSize = window.bounds.size
            eeveeLog("[Landscape][Geometry] window %@, root bounds %@, root frame %@, transform %@",
                     NSCoder.string(for: window.bounds), NSCoder.string(for: host.bounds),
                     NSCoder.string(for: host.frame), NSCoder.string(for: host.transform))
        }
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
        card.setNeedsLayout()
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
        lastWindowSize = nil
        player?.restore(); player = nil
        rail?.removeFromSuperview(); rail = nil
        bar?.alpha = 1; bar?.isUserInteractionEnabled = true
        let saved = clipping; clipping.removeAll()
        for state in saved.values { state.view?.clipsToBounds = state.clips }
    }

    static func contentBottom(in window: UIWindow) -> CGFloat {
        (frames(window)?.player.minY ?? window.safeAreaLayoutGuide.layoutFrame.maxY - 64) - 12
    }

    static func swipeStartRegion(in window: UIWindow) -> CGRect {
        let bottom = playerCard.flatMap { card in
            card.window === window ? card.convert(card.bounds, to: window).maxY : nil
        } ?? window.safeAreaLayoutGuide.layoutFrame.maxY
        let height = window.bounds.height * 0.05
        return CGRect(x: window.bounds.minX, y: bottom - height, width: window.bounds.width, height: height)
    }

    static func contentRight(in window: UIWindow) -> CGFloat {
        (frames(window)?.rail.minX ?? window.safeAreaLayoutGuide.layoutFrame.maxX) - 12
    }

    static func pointInside(_ view: UIView, point: CGPoint) -> Bool? {
        guard let window = view.window, let layout = frames(window) else { return nil }
        let hitFrame = playerHitFrame(in: window, fallback: layout.player)
        let inside = UIBezierPath(roundedRect: hitFrame, cornerRadius: hitFrame.height / 2).contains(view.convert(point, to: window))
        if view === stock { return playerCard?.isDescendant(of: view) == true ? inside : false }
        if view === playerHost || view === playerCard { return inside }
        if playerCard?.isDescendant(of: view) == true, let controller = view.next as? UIViewController,
           NSStringFromClass(type(of: controller)).contains("NowPlaying_BarImpl") { return inside }
        // Extend ancestor hit testing only at the visible card, never across page content.
        if inside, playerCard?.isDescendant(of: view) == true { return true }
        return nil
    }

    private static func playerHitFrame(in window: UIWindow, fallback: CGRect) -> CGRect {
        let visible = playerCard.map { $0.convert($0.bounds, to: window).intersection(fallback) } ?? fallback
        return visible.insetBy(dx: 6, dy: 5)
    }

    static func nativeHit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard let layout = frames(window) else { return nil }
        if let rail, layout.rail.contains(point),
           let hit = NativeHitRouter.hit(rail, at: point, in: window, event: event, region: layout.rail) { return hit }
        let hitFrame = playerHitFrame(in: window, fallback: layout.player)
        if let card = playerCard, UIBezierPath(roundedRect: hitFrame, cornerRadius: hitFrame.height / 2).contains(point) {
            return NativeHitRouter.hit(card, at: point, in: window, event: event, region: hitFrame)
        }
        return nil
    }
}

class LandscapeContentSurfaceHook: ClassHook<UIView> {
    typealias Group = GlassTabBarGroup
    static let targetName = "_TtC19MainUI_TabBarUIImplP33_FD252D04A07ACEB7AD27A83269E8CFAF19TouchForwardingView"

    func layoutSubviews() {
        orig.layoutSubviews()
        if #available(iOS 26.0, *) { LandscapeNavigation.layoutContentSurface(in: target) }
    }
}
