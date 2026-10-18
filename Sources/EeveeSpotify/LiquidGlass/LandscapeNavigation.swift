import UIKit

@available(iOS 26.0, *)
enum LandscapeNavigation {
    private static weak var stock: UIView?
    private static weak var bar: UIView?
    private static weak var playerHost: UIView?
    private static weak var playerCard: UIView?
    private static var player: NativeViewPlacement?
    private static var updating = false
    private struct ClipState { weak var view: UIView?; let clips: Bool }
    private static var clipping: [ObjectIdentifier: ClipState] = [:]

    private static func frames(_ window: UIWindow) -> (tabs: CGRect, player: CGRect)? {
        guard window.bounds.width > window.bounds.height, let stock, stock.window === window else { return nil }
        let safe = window.safeAreaLayoutGuide.layoutFrame
        let left = max(14, safe.minX + 8)
        let right = min(window.bounds.maxX - 14, safe.maxX - 8)
        let width = right - left
        guard width > 500 else { return nil }
        let centerY = min(safe.maxY - 30, stock.convert(stock.bounds, to: window).midY)
        let tabsWidth = min(460, width * 0.53)
        return (CGRect(x: left, y: centerY - 25, width: tabsWidth, height: 50),
                CGRect(x: left + tabsWidth + 12, y: centerY - 30, width: width - tabsWidth - 12, height: 60))
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
        guard let window = stock.window else { return fallback }
        self.stock = stock
        guard let layout = frames(window) else { restore(); return fallback }
        overflow(stock)
        return stock.convert(layout.tabs, from: window)
    }

    static func didLayoutBar(_ bar: UIView, in stock: UIView) {
        guard stock.window != nil else { return }
        self.stock = stock; self.bar = bar
        if let playerHost, let playerCard { layoutPlayer(in: playerHost, card: playerCard) }
    }

    static func layoutPlayer(in host: UIView, card: UIView) {
        playerHost = host; playerCard = card
        guard !updating else { return }
        guard let window = host.window, let layout = frames(window) else {
            if let window = host.window, window.bounds.width <= window.bounds.height { restore() }
            return
        }
        updating = true
        defer { updating = false }
        var slot = card
        while slot !== host, let parent = slot.superview, !(parent is UIWindow),
              parent.bounds.height > 0, parent.bounds.height < window.bounds.height * 0.5,
              parent.bounds.width > window.bounds.width * 0.5 {
            if let stock, stock.isDescendant(of: parent) { break }
            slot = parent
        }
        if player?.view !== slot {
            player?.restore()
            player = NativeViewPlacement(slot)
            eeveeLog("[Landscape][Dock] mini player beside navigation")
        }
        guard let player else { return }
        let scale = min(1, 60 / max(1, player.originalHeight))
        let rect = CGRect(x: layout.player.minX, y: layout.player.midY - player.originalHeight * scale / 2,
                          width: layout.player.width, height: player.originalHeight * scale)
        player.place(rect, in: window, scale: scale)
        overflow(slot)
        host.layoutIfNeeded()
    }

    private static func restore() {
        player?.restore(); player = nil
        let saved = clipping; clipping.removeAll()
        for state in saved.values { state.view?.clipsToBounds = state.clips }
    }

    static func nativeHit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard window.bounds.width > window.bounds.height else { return nil }
        for root in [bar, player?.view].compactMap({ $0 }) {
            if let hit = NativeHitRouter.hit(root, at: point, in: window, event: event) { return hit }
        }
        return nil
    }
}
