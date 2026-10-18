import UIKit
import SwiftUI

/// Replace the Canvas layer; native header, song information, and transport stay above it.
final class KaraokeOverlayPresenter {
    private static let enabledKey = "eeveeEmbeddedLyricsEnabled"
    private(set) static var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    private(set) static var isPresented = false
    private static var restoreScheduled = false
    private static var retryCount = 0
    private static weak var canvas: UIView?
    private static weak var header: UIView?
    private static weak var information: UIView?
    private static weak var footer: UIView?
    private static var hosting: UIViewController?
    private static var container: KaraokeCanvasContainer?
    private static let viewport = KaraokeViewport()
    static let coverClass = "_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView"

    static func registerPlayer(_ root: UIView) {
        footer = root
        restoreIfNeeded()
    }

    static func registerCanvas(_ root: UIView) {
        guard root.window != nil else { return }
        if canvas !== root, isPresented { removeHosting() }
        canvas = root
        if isPresented { updateFrame() } else { restoreIfNeeded() }
    }

    static func registerHeader(_ root: UIView) {
        header = root
        if isPresented { updateFrame() } else { restoreIfNeeded() }
    }

    static func registerInformation(_ root: UIView) {
        information = root
        if isPresented { updateFrame() } else { restoreIfNeeded() }
    }

    static func layout(in candidate: UIView) {
        guard candidate.window != nil else { return }
        if isPresented { updateFrame() } else { restoreIfNeeded() }
    }

    private static func unitFrame(_ unit: UIView, in canvas: UIView) -> CGRect? {
        // Unit roots may be fullscreen passthrough views; measure their real arranged content.
        if let stack = unit.eeveeFirst(UIStackView.self, where: {
            !$0.isHidden && $0.alpha > 0 && $0.bounds.height > 8 && $0.bounds.height < canvas.bounds.height * 0.45
        }) {
            return stack.convert(stack.bounds, to: canvas)
        }
        guard unit.bounds.height > 8, unit.bounds.height < canvas.bounds.height * 0.45 else { return nil }
        return unit.convert(unit.bounds, to: canvas)
    }

    private static func lyricsFrame(in canvas: UIView) -> CGRect? {
        guard let window = canvas.window, let information,
              information.window === window, canvas.bounds.width > 100,
              let infoFrame = unitFrame(information, in: canvas) else { return nil }
        let safeTop = window.convert(window.safeAreaLayoutGuide.layoutFrame, to: canvas).minY
        var contentTop = safeTop
        if let header, header.window === window, !header.isHidden, header.alpha > 0.01,
           let headerFrame = unitFrame(header, in: canvas) { contentTop = max(contentTop, headerFrame.maxY) }
        let top = max(canvas.bounds.minY, contentTop + 8)
        let bottom = min(canvas.bounds.maxY, infoFrame.minY - 8)
        guard bottom - top > 100 else { return nil }
        return CGRect(x: 0, y: top - canvas.bounds.minY, width: canvas.bounds.width, height: bottom - top)
    }

    private static func updateFrame() {
        guard let canvas, let container, let hosting else { return }
        guard canvas.window != nil, let frame = lyricsFrame(in: canvas) else {
            container.isHidden = true
            return
        }
        container.isHidden = false
        if container.frame != canvas.bounds { container.frame = canvas.bounds }
        if hosting.view.frame != container.bounds { hosting.view.frame = container.bounds }
        container.activeRect = frame
        if viewport.frame != frame { viewport.frame = frame }
        // Some player versions nest the foreground units inside the Canvas controller.
        for unit in [header, information, footer].compactMap({ $0 }) {
            var branch = unit
            while let parent = branch.superview, parent !== canvas { branch = parent }
            if branch.superview === canvas, branch !== container,
               let planeIndex = canvas.subviews.firstIndex(of: container),
               let unitIndex = canvas.subviews.firstIndex(of: branch), planeIndex > unitIndex {
                canvas.insertSubview(container, belowSubview: branch)
            }
        }
    }

    static func detached(_ candidate: UIView) {
        if canvas?.window == nil { removeHosting() }
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
        retryCount = 0
        if !show() { restoreIfNeeded() }
    }

    static func restoreIfNeeded() {
        guard isEnabled, UserDefaults.karaokeOptions.enabled, UserDefaults.lyricsSource.supportsCustomLyricsView,
              !isPresented, !restoreScheduled else { return }
        restoreScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            restoreScheduled = false
            guard isEnabled else { return }
            if !show(), retryCount < 4 {
                retryCount += 1
                restoreIfNeeded()
            }
        }
    }

    private static func show() -> Bool {
        if isPresented { return true }
        guard #available(iOS 15.0, *), let canvas, canvas.window != nil,
              let frame = lyricsFrame(in: canvas), UserDefaults.karaokeOptions.enabled,
              UserDefaults.lyricsSource.supportsCustomLyricsView else { return false }
        var responder: UIResponder? = canvas
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController else { return false }
        let tracker = KaraokePlaybackTracker.shared
        guard let trackId = tracker.playerReportedTrackId() ?? tracker.currentTrackId() else { return false }
        viewport.frame = frame
        let child = UIHostingController(rootView: KaraokeLyricsView(trackId: trackId,
            lyrics: KaraokeLyricsStore.shared.lyrics(forTrackId: trackId), viewport: viewport, onDismiss: dismiss))
        child.overrideUserInterfaceStyle = .dark
        child.view.backgroundColor = .clear
        let plane = KaraokeCanvasContainer(frame: canvas.bounds)
        plane.activeRect = frame
        plane.clipsToBounds = true
        controller.addChild(child)
        canvas.addSubview(plane)
        plane.addSubview(child.view)
        child.view.frame = plane.bounds
        child.didMove(toParent: controller)
        container = plane
        hosting = child
        isPresented = true
        retryCount = 0
        updateFrame()
        writeDebugLog("[Karaoke] Canvas replacement mounted; lyrics viewport \(frame)")
        return true
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
        container?.removeFromSuperview()
        container = nil
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

/// Canvas background can fill the layer while touches outside the lyrics reach native controls.
private final class KaraokeCanvasContainer: UIView {
    var activeRect = CGRect.zero
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { activeRect.contains(point) }
}
