import EeveeSpotifyC
import Orion
import UIKit

struct GlassNowPlayingBarGroup: HookGroup {}

@available(iOS 26.0, *)
enum GlassNowPlayingBar {
    static let meter = PerfMeter("Glass][NowPlayingBar")
    private static let landscapeTap = LandscapePlaybackBarTap()
    private static weak var card: UIView?
    private static weak var pane: UIVisualEffectView?
    private static weak var container: UIViewController?
    private static weak var artwork: UIView?
    private static var albumColor: UIColor?
    private static var misses = 0
    private static var styled: Styled?
    private static var portrait: NativeViewPlacement?
    private static var progress: NativeViewPlacement?
    private static let progressMask = CAShapeLayer()
    private static var originalProgressMask: CALayer?
    private static var options = UserDefaults.nowPlayingBarOptions
    private static let observer = NotificationCenter.default.addObserver(
        forName: .eeveeNowPlayingBarOptionsChanged, object: nil, queue: .main
    ) { _ in
        options = UserDefaults.nowPlayingBarOptions
        eeveeLog("[EeveeSpotify][Glass] Now playing bar options changed")
        if let container { style(container) }
    }

    private struct Styled: Equatable {
        let frame: CGRect
        let artwork: CGSize?
        let options: NowPlayingBarOptions
    }

    private static var tint: UIColor? {
        options.albumTint ? albumColor?.withAlphaComponent(0.2) : nil
    }

    static func style(_ container: UIViewController) {
        _ = observer
        self.container = container
        guard let host = container.viewIfLoaded else { return }
        host.backgroundColor = .clear

        if card?.isDescendant(of: host) != true {
            guard let found = findCard(in: host) else {
                if misses < 10 {
                    misses += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak container] in
                        if let container { style(container) }
                    }
                }
                return
            }
            card = found
            misses = 0
            let intercepted = EeveeInterceptBackground(found) { color in
                albumColor = color
                AlbumColor.publish(color)
                if let pane { GlassKit.tint(pane, tint) }
            }
            eeveeLog("[EeveeSpotify][Glass] Now playing card %@ %@, color %@",
                  NSStringFromClass(type(of: found)), NSCoder.string(for: found.frame), intercepted ? "intercepted" : "FAILED")
        }
        guard let card else { return }
        landscapeTap.bind(card: card, container: container)
        NowPlayingBarStartup.nativeReady(card)
        if progress?.view?.isDescendant(of: host) != true {
            if let view = progress?.view, view.layer.mask === progressMask { view.layer.mask = originalProgressMask }
            progress?.restore()
            progress = findProgress(in: host, card: card).map(NativeViewPlacement.init)
            originalProgressMask = progress?.view?.layer.mask
            if let view = progress?.view {
                eeveeLog("[EeveeSpotify][Glass] Mini progress %@", NSStringFromClass(type(of: view)))
            }
        }
        let landscape = host.window.map { $0.bounds.width > $0.bounds.height } ?? false
        if landscape { portrait?.restore(); portrait = nil }
        LandscapeNavigation.layoutPlayer(in: host, card: card)
        if !landscape, let window = host.window, let tabs = GlassTabBar.capsuleFrame(in: window) {
            if portrait?.view !== card { portrait?.restore(); portrait = NativeViewPlacement(card) }
            let native = card.convert(card.bounds, to: window)
            portrait?.place(CGRect(x: tabs.minX, y: native.minY, width: tabs.width, height: native.height), in: window)
            card.layoutIfNeeded()
        }
        card.clipsToBounds = true
        if let window = host.window, let view = progress?.view {
            let rect = card.convert(card.bounds, to: window)
            let height = min(2, max(1, view.bounds.height))
            progress?.place(CGRect(x: rect.minX, y: rect.maxY - height,
                                   width: rect.width, height: height), in: window)
            view.layoutIfNeeded()
            // Keep the native line at the bottom, clipped to the same capsule as the glass.
            let capsule = view.convert(card.bounds, from: card)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            progressMask.frame = view.bounds
            progressMask.path = UIBezierPath(roundedRect: capsule, cornerRadius: capsule.height / 2).cgPath
            view.layer.mask = progressMask
            CATransaction.commit()
        }
        if artwork?.isDescendant(of: card) != true { artwork = findArtwork(in: card) }
        let frame = card.convert(card.bounds, to: host)
        let now = Styled(frame: frame, artwork: artwork?.bounds.size, options: options)
        if now == styled, let pane, pane.superview === host, host.subviews.first === pane, pane.frame == frame,
           card.layer.cornerRadius == card.bounds.height / 2, artwork.map({ $0.layer.cornerRadius == artworkRadius($0) }) != false {
            GlassKit.tint(pane, tint)
            return
        }
        styled = now
        let radius = card.bounds.height / 2
        if card.layer.cornerRadius != radius {
            card.layer.cornerRadius = radius
            card.layer.cornerCurve = .continuous
        }
        // Clipping can't live in the radius check: iPad already ships a capsule corner radius, so the
        // branch is skipped there and the artwork renders straight past the rounded corners.
        card.clipsToBounds = true

        let glass = GlassKit.pane(in: host)
        pane = glass
        if glass.frame != frame {
            glass.frame = frame
            glass.cornerConfiguration = .capsule()
        }
        GlassKit.tint(glass, tint)

        if let artwork {
            artwork.layer.cornerRadius = artworkRadius(artwork)
            artwork.layer.cornerCurve = .continuous
            artwork.clipsToBounds = true
        }
    }

    static func refreshLayout() {
        if let container { style(container) }
    }

    private static func findProgress(in host: UIView, card: UIView) -> UIView? {
        let cardRect = card.convert(card.bounds, to: host)
        var best: UIView?
        var score: CGFloat = -1
        var queue = host.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view is UIVisualEffectView { continue }
            queue += view.subviews
            guard view !== card, !card.isDescendant(of: view), !view.isHidden,
                  view.bounds.height > 0, view.bounds.height <= 8,
                  view.bounds.width >= card.bounds.width * 0.5 else { continue }
            let name = NSStringFromClass(type(of: view)).lowercased()
            let named = view is UIProgressView || name.contains("progress")
                || view.accessibilityIdentifier?.lowercased().contains("progress") == true
            let distance = abs(view.convert(view.bounds, to: host).midY - cardRect.maxY)
            guard named || distance <= 8 else { continue }
            let candidate = (named ? 1000 : 0) + view.bounds.width - distance
            if candidate > score { best = view; score = candidate }
        }
        return best
    }

    private static func artworkRadius(_ artwork: UIView) -> CGFloat {
        options.roundArtwork ? artwork.bounds.width / 2 : 12
    }

    // The iPad bar is taller than the iPhone one, so a fixed 32...56pt window misses its artwork entirely.
    // The bar's own height is the limit instead, and the leftmost qualifying view wins.
    private static func findArtwork(in card: UIView) -> UIView? {
        let limit = card.bounds.height
        guard limit > 0 else { return nil }
        var best: UIView?
        var bestMinX = CGFloat.greatestFiniteMagnitude
        var queue = card.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            queue += view.subviews
            let size = view.bounds.size
            guard size.width >= 24, size.width <= limit, abs(size.width - size.height) < 1 else { continue }
            let minX = view.convert(view.bounds, to: card).minX
            guard minX < card.bounds.width / 3, minX < bestMinX else { continue }
            bestMinX = minX
            best = view
        }
        return best
    }

    private static func findCard(in root: UIView) -> UIView? {
        var best: UIView?
        var bestArea: CGFloat = 0
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            queue += view.subviews
            guard !(view is UIVisualEffectView), let color = view.backgroundColor, color.isOpaqueish else { continue }
            let size = view.bounds.size
            guard size.width >= 200, size.height >= 40, size.height <= 160,
                  root.bounds.contains(view.convert(view.bounds, to: root)) else { continue }
            if size.width * size.height > bestArea {
                bestArea = size.width * size.height
                best = view
            }
        }
        return best
    }
}

@objc private protocol NativePlaybackBarOpening {
    func didPerformTap()
}

@available(iOS 26.0, *)
private final class LandscapePlaybackBarTap: NSObject, UIGestureRecognizerDelegate {
    private weak var card: UIView?
    private weak var controller: UIViewController?
    private lazy var tap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(openPlayer(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()

    func bind(card: UIView, container: UIViewController) {
        controller = container.children.first { $0.responds(to: NSSelectorFromString("didPerformTap")) }
        if self.card !== card {
            self.card?.removeGestureRecognizer(tap)
            self.card = card
            card.addGestureRecognizer(tap)
        }
        let enabled = controller != nil && card.window.map { $0.bounds.width > $0.bounds.height } == true
        if tap.isEnabled != enabled { tap.isEnabled = enabled }
    }

    @objc private func openPlayer(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let controller, let window = card?.window,
              window.bounds.width > window.bounds.height else { return }
        // Call Spotify's own tap action; its original gesture delegate uses the unmoved bar region.
        unsafeBitCast(controller, to: NativePlaybackBarOpening.self).didPerformTap()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var candidate = touch.view
        while let view = candidate, view !== card {
            if view is UIControl || view.accessibilityTraits.contains(.button)
                || view.accessibilityTraits.contains(.adjustable) { return false }
            candidate = view.superview
        }
        return true
    }
}

class GlassNowPlayingBarContainerHook: ClassHook<UIViewController> {
    typealias Group = GlassNowPlayingBarGroup
    static let targetName = "_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard #available(iOS 26.0, *) else { return }
        GlassNowPlayingBar.meter.measure { GlassNowPlayingBar.style(target) }
    }
}

class GlassNowPlayingBarHook: ClassHook<UIViewController> {
    typealias Group = GlassNowPlayingBarGroup
    static let targetName = "_TtC18NowPlaying_BarImpl27NowPlayingBarViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard #available(iOS 26.0, *), let container = target.parent,
              NSStringFromClass(type(of: container)).contains("NowPlayingBarContainer") else { return }
        GlassNowPlayingBar.meter.measure { GlassNowPlayingBar.style(container) }
    }
}

// This page wrapper retains its old horizontal frame after the visible card moves.
// Its hosted background must not intercept rows above the relocated player.
class LandscapePlayerPassthroughHook: ClassHook<UIView> {
    typealias Group = GlassNowPlayingBarGroup
    static let targetName = "_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView"

    @objc(hitTest:withEvent:) func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if #available(iOS 26.0, *), let window = target.window,
           LandscapeNavigation.acceptsPlayerHit(at: target.convert(point, to: window), in: window) == false {
            return nil
        }
        return orig.hitTest(point, with: event)
    }
}
