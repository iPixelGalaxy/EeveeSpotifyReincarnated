import UIKit
import SwiftUI

/// Hosts lyrics in the artwork rectangle. Spotify retains its own transport and footer controls.
final class KaraokeOverlayPresenter {
    private(set) static var isPresented = false
    private static weak var cover: UIView?
    private static var hosting: UIViewController?
    private static var previousAccessibilityHidden = false
    static let coverClass = "_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView"

    static func layout(in candidate: UIView) {
        guard candidate.window != nil, candidate.bounds.width > 100,
              candidate.bounds.height > 100, PlayerPlacement.contains(candidate) else { return }
        if !isPresented { cover = candidate; return }
        guard candidate === cover, let parent = candidate.superview, let hosting else { return }
        let frame = candidate.convert(candidate.bounds, to: parent)
        if hosting.view.superview !== parent { parent.insertSubview(hosting.view, aboveSubview: candidate) }
        if hosting.view.frame != frame { hosting.view.frame = frame }
    }

    static func detached(_ candidate: UIView) {
        if candidate === cover, candidate.window == nil { dismiss() }
    }

    static func present() {
        if isPresented { dismiss(); return }
        guard #available(iOS 15.0, *), UserDefaults.karaokeOptions.enabled,
              UserDefaults.lyricsSource.supportsCustomLyricsView else { return }
        if cover?.window == nil {
            let root = WindowHelper.shared.rootViewController.view
            cover = root?.eeveeFirst(UIView.self, where: {
                NSStringFromClass(type(of: $0)) == coverClass && $0.window != nil && PlayerPlacement.contains($0)
            })
        }
        guard let cover, let parent = cover.superview else {
            writeDebugLog("[Karaoke] artwork surface unavailable; open Now Playing first")
            return
        }
        var responder: UIResponder? = parent
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
        parent.insertSubview(child.view, aboveSubview: cover)
        child.view.frame = cover.convert(cover.bounds, to: parent)
        child.didMove(toParent: controller)
        previousAccessibilityHidden = cover.accessibilityElementsHidden
        cover.accessibilityElementsHidden = true
        hosting = child
        isPresented = true
    }

    static func dismiss() {
        guard let hosting else { return }
        hosting.willMove(toParent: nil)
        hosting.view.removeFromSuperview()
        hosting.removeFromParent()
        cover?.accessibilityElementsHidden = previousAccessibilityHidden
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
