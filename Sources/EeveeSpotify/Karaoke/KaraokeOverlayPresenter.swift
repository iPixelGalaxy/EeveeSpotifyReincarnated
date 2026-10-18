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
    private static weak var controls: UIView?
    private static weak var duration: UIView?
    private static var idleWork: DispatchWorkItem?
    private static let activityObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        if isPresented && isEnabled && !focused { interact() }
    }
    private static var focused = false
    private static var suspended = false
    private static var nativeTouchActive = false
    private static var nativeMonitor: KaraokeControlTouchMonitor?
    private static weak var playerRoot: UIView?
    private static var loggedRoot: ObjectIdentifier?
    private struct ScrollState {
        weak var view: UIScrollView?
        let enabled: Bool
        let bounces: Bool
    }
    private static var outerScrolls: [ObjectIdentifier: ScrollState] = [:]
    private static var dismissing = false
    private static var focusShift: CGFloat = 0
    private struct NativeState {
        weak var view: UIView?
        let alpha: CGFloat
        let transform: CGAffineTransform
        let interactive: Bool
        init(_ view: UIView) { self.view = view; alpha = view.alpha; transform = view.transform; interactive = view.isUserInteractionEnabled }
    }
    private static var nativeStates: [ObjectIdentifier: NativeState] = [:]

    static func nativeTouchBegan(_ touch: UITouch) -> Bool {
        guard isPresented else { return false }
        if let touched = touch.view, let container, touched.isDescendant(of: container) { return false }
        nativeTouchActive = true
        idleWork?.cancel()
        writeDebugLog("[Karaoke][touch] native control began; pause idle timer")
        return true
    }
    static func nativeTouchEnded() {
        nativeTouchActive = false
        writeDebugLog("[Karaoke][touch] native control ended; restart idle timer")
        interact()
    }

    static func registerControls(_ view: UIView) {
        let replaced = controls !== view && focused
        if replaced { setFocused(false) }
        controls = view
        if replaced { interact() }
        if isPresented { view.alpha = focused ? 0 : 1; view.isUserInteractionEnabled = !focused }
    }
    static func registerDuration(_ view: UIView) {
        let replaced = duration !== view && focused
        if replaced { setFocused(false) }
        duration = view
        if replaced { interact() }
    }

    static func resumePlayer(_ controller: UIViewController) {
        suspended = false
        playerRoot = controller.viewIfLoaded
        loggedRoot = nil
        writeDebugLog("[Karaoke][lifecycle] Now Playing appeared; lyrics enabled=\(isEnabled)")
        restoreIfNeeded()
        if isPresented { interact() }
    }

    static func suspendPlayer() {
        suspended = true
        writeDebugLog("[Karaoke][lifecycle] Now Playing disappeared; preserve lyrics=\(isEnabled)")
        removeHosting()
    }

    static func collapsePlayer() {
        guard isPresented else { return }
        let window = canvas?.window
        var candidates: [UIControl] = []
        if let header {
            var queue = [header]
            while !queue.isEmpty {
                let view = queue.removeLast()
                queue.append(contentsOf: view.subviews)
                if let control = view as? UIControl, let window,
                   control.convert(control.bounds, to: window).midX < window.bounds.width * 0.25,
                   control.bounds.width > 0, !control.isHidden, control.alpha > 0.01, control.isEnabled,
                   !control.allControlEvents.isEmpty { candidates.append(control) }
            }
        }
        var modal = canvas?.next as? UIViewController
        if modal == nil { modal = hosting?.parent }
        while let parent = modal?.parent { modal = parent }
        suspendPlayer()
        if let button = candidates.first {
            button.sendActions(for: button.allControlEvents.contains(.touchUpInside) ? .touchUpInside : .primaryActionTriggered)
            writeDebugLog("[Karaoke][gesture] collapsed through native header control")
        } else if let modal, modal.presentingViewController != nil {
            modal.dismiss(animated: true)
            writeDebugLog("[Karaoke][gesture] dismissed native player controller")
        } else {
            suspended = false
            restoreIfNeeded()
            writeDebugLog("[Karaoke][gesture] no native dismissal target; kept lyrics")
        }
    }

    static func layoutPlayer(_ controller: UIViewController) {
        guard let root = controller.viewIfLoaded else { return }
        playerRoot = root
        guard isPresented else { return }
        if nativeMonitor?.view !== root {
            nativeMonitor?.view?.removeGestureRecognizer(nativeMonitor!)
            let monitor = KaraokeControlTouchMonitor()
            root.addGestureRecognizer(monitor)
            nativeMonitor = monitor
        }
        var queue = [root]
        let logHierarchy = UserDefaults.debugLoggingEnabled && loggedRoot != ObjectIdentifier(root)
        if logHierarchy { loggedRoot = ObjectIdentifier(root) }
        var logged: Set<String> = []
        while !queue.isEmpty {
            let view = queue.removeLast()
            if view === container { continue }
            if logHierarchy {
                let name = NSStringFromClass(type(of: view))
                if logged.count < 40, ["Lyrics", "NowPlaying_", "Martini", "Recommend", "Share", "Fullscreen"].contains(where: name.contains), logged.insert(name).inserted {
                    writeDebugLog("[Karaoke][hierarchy] \(name) id=\(view.accessibilityIdentifier ?? "-") frame=\(view.convert(view.bounds, to: root)) alpha=\(view.alpha)")
                }
            }
            queue.append(contentsOf: view.subviews)
            if let scroll = view as? UIScrollView,
               scroll.bounds.height > root.bounds.height * 0.5,
               scroll.contentSize.width <= scroll.bounds.width + 1,
               canvas?.isDescendant(of: scroll) == true {
                let id = ObjectIdentifier(scroll)
                if outerScrolls[id] == nil { outerScrolls[id] = ScrollState(view: scroll, enabled: scroll.isScrollEnabled, bounces: scroll.bounces) }
                scroll.isScrollEnabled = false
                scroll.bounces = false
                if abs(scroll.contentOffset.y) > 1 { scroll.setContentOffset(.zero, animated: false) }
            }
        }
        for view in [controls, footer].compactMap({ $0 }) {
            view.alpha = focused ? 0 : 1
            view.isUserInteractionEnabled = !focused
        }
        updateFrame()
    }

    static func interact(dragging: Bool = false) {
        idleWork?.cancel()
        setFocused(false)
        if isPresented {
            for view in [controls, footer].compactMap({ $0 }) { view.alpha = 1; view.isUserInteractionEnabled = true }
        }
        guard isPresented, isEnabled, !dragging, !nativeTouchActive, !suspended else { return }
        let work = DispatchWorkItem {
            if isPresented && isEnabled && UIApplication.shared.applicationState == .active && !UIAccessibility.isVoiceOverRunning { setFocused(true) }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private static func setFocused(_ value: Bool) {
        guard focused != value else { return }
        focused = value
        writeDebugLog("[Karaoke][focus] focused=\(value) positionMs=\(KaraokePlaybackTracker.shared.currentPositionMs()) info=\(String(describing: information?.frame)) controls=\(String(describing: controls?.frame))")
        if value, let canvas, let window = canvas.window, let information,
           let infoFrame = unitFrame(information, in: window), infoFrame.intersects(window.bounds) {
            for view in [information, duration, controls, footer].compactMap({ $0 }) {
                nativeStates[ObjectIdentifier(view)] = NativeState(view)
            }
            let end = duration.flatMap { unitFrame($0, in: window)?.maxY } ?? infoFrame.maxY
            focusShift = max(0, window.safeAreaLayoutGuide.layoutFrame.maxY - 8 - end)
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                for view in [information, duration].compactMap({ $0 }) {
                    if let saved = nativeStates[ObjectIdentifier(view)] {
                        let vector = view.superview?.convert(CGPoint(x: 0, y: focusShift), from: window) ?? CGPoint(x: 0, y: focusShift)
                        let origin = view.superview?.convert(CGPoint.zero, from: window) ?? .zero
                        var transform = saved.transform
                        transform.tx += vector.x - origin.x
                        transform.ty += vector.y - origin.y
                        view.transform = transform
                    }
                }
                for view in [controls, footer].compactMap({ $0 }) { view.alpha = 0; view.isUserInteractionEnabled = false }
                updateFrame()
            }
        } else {
            if value { focused = false }
            let saved = Array(nativeStates.values)
            nativeStates.removeAll()
            focusShift = 0
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                for state in saved {
                    state.view?.transform = state.transform
                    state.view?.alpha = state.alpha
                    state.view?.isUserInteractionEnabled = state.interactive
                }
                for view in [controls, footer].compactMap({ $0 }) {
                    view.alpha = 1
                    view.isUserInteractionEnabled = true
                }
                updateFrame()
            }
        }
    }

    static let coverClass = "_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView"

    static func registerPlayer(_ root: UIView) {
        let replaced = footer !== root && focused
        if replaced { setFocused(false) }
        footer = root
        if replaced { interact() }
        if isPresented { root.alpha = focused ? 0 : 1; root.isUserInteractionEnabled = !focused }
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
        let replaced = information !== root && focused
        if replaced { setFocused(false) }
        information = root
        if replaced { interact() }
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

    private static func refreshFocusGeometry() {
        guard focused, let canvas, let window = canvas.window, let information else { return }
        let endView = duration ?? information
        guard let endFrame = unitFrame(endView, in: window),
              let savedEnd = nativeStates[ObjectIdentifier(endView)] else { return }
        let target = window.safeAreaLayoutGuide.layoutFrame.maxY - 8
        guard abs(endFrame.maxY - target) > 1 else { return }
        // Spotify can change its own Canvas layout while focused; measure its new baseline.
        let translation = CGPoint(x: endView.transform.tx - savedEnd.transform.tx,
                                  y: endView.transform.ty - savedEnd.transform.ty)
        let moved = endView.superview?.convert(translation, to: window) ?? translation
        let origin = endView.superview?.convert(CGPoint.zero, to: window) ?? .zero
        focusShift = max(0, target - (endFrame.maxY - (moved.y - origin.y)))
        for view in [information, duration].compactMap({ $0 }) {
            guard let saved = nativeStates[ObjectIdentifier(view)] else { continue }
            let shifted = view.superview?.convert(CGPoint(x: 0, y: focusShift), from: window) ?? CGPoint(x: 0, y: focusShift)
            let zero = view.superview?.convert(CGPoint.zero, from: window) ?? .zero
            var transform = saved.transform
            transform.tx += shifted.x - zero.x
            transform.ty += shifted.y - zero.y
            view.transform = transform
        }
    }

    private static func updateFrame() {
        refreshFocusGeometry()
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
        for unit in [header, information, duration, controls, footer].compactMap({ $0 }) {
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
        guard !suspended else { return }
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
        dismissing = false
        _ = activityObserver
        if isPresented {
            container?.layer.removeAllAnimations()
            container?.alpha = 1
            interact()
            return true
        }
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
        if #available(iOS 16.4, *) { child.safeAreaRegions = [] }
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
        plane.alpha = 0
        UIView.animate(withDuration: 0.25) { plane.alpha = 1 }
        container = plane
        hosting = child
        isPresented = true
        retryCount = 0
        updateFrame()
        interact()
        if let controller = playerRoot?.next as? UIViewController { layoutPlayer(controller) }
        writeDebugLog("[Karaoke] Canvas replacement mounted; lyrics viewport \(frame)")
        return true
    }

    static func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        setEnabled(false)
        idleWork?.cancel()
        setFocused(false)
        guard let container else { removeHosting(); return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            container.alpha = 0
        } completion: { finished in
            dismissing = false
            if finished && !isEnabled { removeHosting() }
        }
    }

    private static func removeHosting() {
        dismissing = false
        nativeTouchActive = false
        if let monitor = nativeMonitor { monitor.view?.removeGestureRecognizer(monitor) }
        nativeMonitor = nil
        idleWork?.cancel()
        setFocused(false)
        for saved in outerScrolls.values {
            saved.view?.isScrollEnabled = saved.enabled
            saved.view?.bounces = saved.bounces
        }
        outerScrolls.removeAll()
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

/// Observe native sliders/buttons without delaying, cancelling, or recognizing their touches.
private final class KaraokeControlTouchMonitor: UIGestureRecognizer {
    private var trackingNative = false
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, KaraokeOverlayPresenter.nativeTouchBegan(touch) else { state = .failed; return }
        trackingNative = true
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackingNative { KaraokeOverlayPresenter.nativeTouchEnded() }
        trackingNative = false
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackingNative { KaraokeOverlayPresenter.nativeTouchEnded() }
        trackingNative = false
        state = .failed
    }
    override func reset() { super.reset(); trackingNative = false }
}
