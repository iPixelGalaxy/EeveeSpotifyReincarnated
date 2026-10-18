import UIKit
import SwiftUI

/// Hosts lyrics in the artwork rectangle. Spotify retains its own transport and footer controls.
final class KaraokeOverlayPresenter {
    private static let enabledKey = "eeveeEmbeddedLyricsEnabled"
    private(set) static var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    private(set) static var isPresented = false
    private static var restoreScheduled = false
    private static weak var cover: UIView?
    private static var hosting: UIViewController?
    private static var previousAccessibilityHidden = false
    private static weak var artwork: UIView?
    static let coverClass = "_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView"

    /// The collection includes title/controls; only its visible square artwork is the lyrics slot.
    private static func artworkSurface(in candidate: UIView) -> UIView? {
        var queue = candidate.subviews
        var best: (view: UIView, priority: Int, area: CGFloat)?
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view === hosting?.view { continue }
            queue.append(contentsOf: view.subviews)
            guard !view.isHidden, view.alpha > 0, view.bounds.width > 100, view.bounds.height > 100 else { continue }
            let ratio = view.bounds.width / view.bounds.height
            guard ratio > 0.8, ratio < 1.25 else { continue }
            let tilt = NSStringFromClass(type(of: view)).contains("CoverArtTiltView")
            guard tilt || (view as? UIImageView)?.image != nil else { continue }
            let frame = view.convert(view.bounds, to: candidate)
            let visible = frame.intersection(candidate.bounds)
            guard !visible.isNull, visible.width > 100, visible.height > 100 else { continue }
            let priority = tilt ? 2 : 1
            let area = visible.width * visible.height
            if priority > (best?.priority ?? 0) || (priority == best?.priority && area > (best?.area ?? 0)) {
                best = (view, priority, area)
            }
        }
        return best?.view
    }

    static func layout(in candidate: UIView) {
        guard candidate.window != nil, candidate.bounds.width > 100,
              candidate.bounds.height > 100, PlayerPlacement.contains(candidate) else { return }
        guard let window = candidate.window,
              !candidate.convert(candidate.bounds, to: window).intersection(window.bounds).isEmpty else { return }
        if candidate !== cover, isPresented { removeHosting() }
        if !isPresented {
            cover = candidate
            restoreIfNeeded()
            return
        }
        guard candidate === cover, let hosting else { return }
        guard let surface = artworkSurface(in: candidate) else {
            hosting.view.isHidden = true
            return
        }
        hosting.view.isHidden = false
        let frame = surface.convert(surface.bounds, to: candidate)
        if hosting.view.superview !== candidate { candidate.addSubview(hosting.view) }
        if candidate.subviews.last !== hosting.view { candidate.bringSubviewToFront(hosting.view) }
        if hosting.view.frame != frame { hosting.view.frame = frame }
    }

    static func detached(_ candidate: UIView) {
        if candidate === cover, candidate.window == nil { removeHosting() }
    }

    private static func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        KaraokeLyricsStore.shared.notify()
    }

    static func toggle() {
        if isEnabled { dismiss() } else { present() }
    }

    static func present() {
        setEnabled(true)
        show()
    }

    static func restoreIfNeeded() {
        guard isEnabled, !isPresented, !restoreScheduled, cover?.window != nil else { return }
        restoreScheduled = true
        DispatchQueue.main.async {
            restoreScheduled = false
            if isEnabled { show() }
        }
    }

    private static func show() {
        guard !isPresented else { return }
        guard #available(iOS 15.0, *), UserDefaults.karaokeOptions.enabled,
              UserDefaults.lyricsSource.supportsCustomLyricsView else { return }
        if cover?.window == nil {
            let root = WindowHelper.shared.rootViewController.view
            cover = root?.eeveeFirst(UIView.self, where: {
                NSStringFromClass(type(of: $0)) == coverClass && $0.window != nil && PlayerPlacement.contains($0)
            })
        }
        guard let cover, let surface = artworkSurface(in: cover) else {
            writeDebugLog("[Karaoke] artwork surface unavailable; open Now Playing first")
            return
        }
        var responder: UIResponder? = cover
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController else { return }
        let tracker = KaraokePlaybackTracker.shared
        guard let trackId = tracker.playerReportedTrackId() ?? tracker.currentTrackId() else { return }
        let lyrics = KaraokeLyricsStore.shared.lyrics(forTrackId: trackId)
        let child = UIHostingController(rootView: KaraokeLyricsView(trackId: trackId, lyrics: lyrics, onDismiss: dismiss))
        child.overrideUserInterfaceStyle = .dark
        child.view.backgroundColor = .black
        child.view.clipsToBounds = true
        child.view.layer.cornerRadius = 12
        controller.addChild(child)
        cover.addSubview(child.view)
        child.view.frame = surface.convert(surface.bounds, to: cover)
        child.didMove(toParent: controller)
        previousAccessibilityHidden = surface.accessibilityElementsHidden
        surface.accessibilityElementsHidden = true
        artwork = surface
        hosting = child
        isPresented = true
    }

    static func dismiss() {
        setEnabled(false)
        removeHosting()
    }

    private static func removeHosting() {
        guard let hosting else { return }
        hosting.willMove(toParent: nil)
        hosting.view.removeFromSuperview()
        hosting.removeFromParent()
        artwork?.accessibilityElementsHidden = previousAccessibilityHidden
        artwork = nil
        self.hosting = nil
        isPresented = false
    }

    static func isAvailableForCurrentTrack() -> Bool {
        guard UserDefaults.karaokeOptions.enabled, UserDefaults.lyricsSource.supportsCustomLyricsView else { return false }
        let tracker = KaraokePlaybackTracker.shared
        guard let trackId = tracker.playerReportedTrackId() ?? tracker.currentTrackId() else { return false }
        return KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) != nil
    }
}
