import UIKit
import ObjectiveC.runtime
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
    private static var landscapeSidebar: KaraokeLandscapeSidebar?
    private static var updatingFrame = false
    private static var wideClipping: [ObjectIdentifier: VideoState] = [:]
    private static weak var positionedHeader: UIView?
    private static var headerBaseTransform = CGAffineTransform.identity
    private static var changingHeaderFrame = false
    private static var isLandscape: Bool {
        guard let window = canvas?.window else { return false }
        return window.bounds.width > window.bounds.height
    }
    private static weak var controls: UIView?
    private static weak var duration: UIView?
    private static var idleWork: DispatchWorkItem?
    private static let activityObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        if isPresented && isEnabled && !focused { interact() }
    }
    private static var focused = false
    private static var waitingForNativeUnits = false
    private static var suspended = false
    private static var preparingAppearance = false
    private static var mounting = false
    private struct VideoState {
        weak var view: UIView?
        let alpha: CGFloat
        let hidden: Bool
        let interactive: Bool
        let accessibilityHidden: Bool
        let clips: Bool
        init(_ view: UIView) {
            self.view = view; alpha = view.alpha; hidden = view.isHidden
            interactive = view.isUserInteractionEnabled
            accessibilityHidden = view.accessibilityElementsHidden
            clips = view.clipsToBounds
        }
    }
    private static var videoStates: [ObjectIdentifier: VideoState] = [:]
    private static var nativeTouchActive = false
    private static var compactTouch = false
    private static var focusHeartbeat: DispatchSourceTimer?
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

    private static var compactVisibilityKey: UInt8 = 0
    private static var compactTransformKey: UInt8 = 0
    private static var compactVisibility: [ObjectIdentifier: VideoState] = [:]

    static func lockedCompactAlpha(_ value: CGFloat, in view: UIView) -> CGFloat {
        objc_getAssociatedObject(view, &compactVisibilityKey) == nil ? value : 1
    }
    static func lockedCompactHidden(_ value: Bool, in view: UIView) -> Bool {
        objc_getAssociatedObject(view, &compactVisibilityKey) == nil ? value : false
    }
    static func lockedCompactClipping(_ value: Bool, in view: UIView) -> Bool {
        if wideClipping[ObjectIdentifier(view)]?.view === view { return false }
        return objc_getAssociatedObject(view, &compactVisibilityKey) == nil ? value : false
    }
    static func lockedCompactTransform(_ value: CGAffineTransform, in view: UIView) -> CGAffineTransform {
        (objc_getAssociatedObject(view, &compactTransformKey) as? NSValue)?.cgAffineTransformValue ?? value
    }
    static func compactHit(_ point: CGPoint, in view: UIView) -> Bool {
        if wideClipping[ObjectIdentifier(view)]?.view === view, let container {
            if container.isDescendant(of: view), container.point(inside: container.convert(point, from: view), with: nil) { return true }
            if let header, header.isDescendant(of: view), unitFrame(header, in: view)?.contains(point) == true { return true }
        }
        guard focused, objc_getAssociatedObject(view, &compactVisibilityKey) != nil, let controls else { return false }
        return controls.convert(controls.bounds, to: view).contains(point)
    }
    private static func pinCompactVisibility(_ view: UIView) {
        let id = ObjectIdentifier(view)
        if compactVisibility[id]?.view !== view { compactVisibility[id] = VideoState(view) }
        objc_setAssociatedObject(view, &compactVisibilityKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        view.isHidden = false; view.alpha = 1; view.clipsToBounds = false; view.isUserInteractionEnabled = true
    }
    private static func releaseCompactVisibility() {
        for saved in compactVisibility.values {
            guard let view = saved.view else { continue }
            objc_setAssociatedObject(view, &compactVisibilityKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(view, &compactTransformKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            view.isHidden = saved.hidden; view.alpha = saved.alpha; view.clipsToBounds = saved.clips; view.isUserInteractionEnabled = saved.interactive
        }
        compactVisibility.removeAll()
    }
    private static var canHideFooter: Bool {
        guard let footer else { return false }
        return controls?.isDescendant(of: footer) != true
    }
    private static func dismissalBand() -> CGRect? {
        guard let canvas else { return nil }
        let frames = [information, duration, controls].compactMap { $0 }.compactMap { unitFrame($0, in: canvas) }
        guard let first = frames.first else { return nil }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
            .offsetBy(dx: -canvas.bounds.minX, dy: -canvas.bounds.minY)
        return CGRect(x: 0, y: max(0, union.minY - 44), width: canvas.bounds.width, height: union.height + 88)
    }
    static func dismissSwipeStart(_ touch: UITouch) -> (point: CGPoint, band: CGRect)? {
        guard isPresented, let canvas, let container, let touched = touch.view,
              touched.isDescendant(of: container), let hosted = hosting?.view,
              touched.isDescendant(of: hosted), let band = dismissalBand() else { return nil }
        let raw = touch.location(in: canvas)
        let point = CGPoint(x: raw.x - canvas.bounds.minX, y: raw.y - canvas.bounds.minY)
        guard point.y >= 0, point.y < canvas.bounds.height * 0.35 else { return nil }
        return (point, band)
    }
    static func finishDismissSwipe(_ start: (point: CGPoint, band: CGRect), touch: UITouch, speed: CGFloat) {
        guard let canvas else { return }
        let raw = touch.location(in: canvas)
        let end = CGPoint(x: raw.x - canvas.bounds.minX, y: raw.y - canvas.bounds.minY)
        let inControls = start.band.union(dismissalBand() ?? start.band).contains(end)
        let down = end.y - start.point.y
        let close = speed >= 700 && down > 100 && down > abs(end.x - start.point.x) && inControls
        writeDebugLog("[Karaoke][swipe] speed=\(Int(speed)) controls=\(inControls) close=\(close)")
        if close { collapsePlayer() } else { interact() }
    }

    static func landscapeGeometry(for view: UIView) -> KaraokeLandscapeSidebar.Geometry? {
        guard isPresented, isLandscape else { return nil }
        return landscapeSidebar?.geometry(for: view)
    }

    static func routedControlHit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard isPresented, canvas?.window === window else { return nil }
        if isLandscape, let hit = landscapeSidebar?.nativeHit(at: point, in: window, event: event) { return hit }
        // The header moves in portrait too, including while the full controls are showing.
        let roots = [header, footer] + (focused || isLandscape ? [controls, duration, information] : [])
        for root in roots.compactMap({ $0 }) {
            guard let region = unitFrame(root, in: window), region.contains(point) else { continue }
            if let hit = NativeHitRouter.hit(root, at: point, in: window, event: event, region: region) { return hit }
        }
        return nil
    }

    static func nativeTouchBegan(_ touch: UITouch) -> Bool {
        guard isPresented else { return false }
        if let touched = touch.view, let hosted = hosting?.view, touched.isDescendant(of: hosted) { return false }
        nativeTouchActive = true
        compactTouch = focused && touch.view.map { touched in controls.map { touched.isDescendant(of: $0) } ?? false } == true
        idleWork?.cancel()
        writeDebugLog("[Karaoke][touch] native began hit=\(touch.view.map { NSStringFromClass(type(of: $0)) } ?? "nil") compact=\(compactTouch)")
        return true
    }
    static func nativeTouchEnded() {
        nativeTouchActive = false
        let keepCompact = compactTouch && focused
        compactTouch = false
        writeDebugLog("[Karaoke][touch] native control ended; compact=\(keepCompact)")
        // Finish UIKit's control action before changing the layout under its touch.
        if !keepCompact { DispatchQueue.main.async { if isPresented { interact() } } }
    }

    static func registerControls(_ view: UIView) {
        if isPresented, let window = canvas?.window, view.window !== window { return }
        if focused, nativeStates[ObjectIdentifier(view)]?.view !== view { nativeStates[ObjectIdentifier(view)] = NativeState(view) }
        if controls !== view {
            writeDebugLog("[Karaoke][units] bound playback controls window=\(view.window != nil) frame=\(view.frame)")
        }
        controls = view
        if isPresented {
            view.alpha = 1; view.isUserInteractionEnabled = true
            if focused { layoutCompactControls() }
            if isLandscape { updateFrame() }
        }
    }
    static func registerDuration(_ view: UIView) {
        if isPresented, let window = canvas?.window, view.window !== window { return }
        if focused, nativeStates[ObjectIdentifier(view)]?.view !== view { nativeStates[ObjectIdentifier(view)] = NativeState(view) }
        duration = view
        if isPresented { updateFrame() }
    }

    static func preparePlayer(_ controller: UIViewController) {
        preparingAppearance = true
        suspended = false
        retryCount = 0
        playerRoot = controller.viewIfLoaded
        guard isEnabled, UserDefaults.karaokeOptions.enabled,
              UserDefaults.lyricsSource.supportsCustomLyricsView, hasCachedLyrics else { return }
        PlayerDeclutter.setLyricsOverride(true, in: playerRoot)
        controller.viewIfLoaded?.layoutIfNeeded()
        var pending = controller.children
        while let child = pending.popLast() {
            pending.append(contentsOf: child.children)
            let name = NSStringFromClass(type(of: child))
            if name.contains("NowPlaying_ContentLayerPlatformImpl"), name.contains("ContentLayerViewController") {
                child.loadViewIfNeeded()
                if let root = child.viewIfLoaded { registerCanvas(root) }
            }
        }
        writeDebugLog("[Karaoke][lifecycle] preparing cached lyrics before presentation")
        restoreIfNeeded()
    }

    static func suppressVideoSwitch(_ view: UIView) {
        guard isPresented, !suspended else { return }
        if let window = canvas?.window, let ownerWindow = view.window, ownerWindow !== window { return }
        let name = NSStringFromClass(type(of: view))
        let identifier = (view.accessibilityIdentifier ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        guard name.contains("AudioVideoSwitch") || name.contains("AudioVideoElementProps") ||
              identifier.contains("switchtovideo") || identifier.contains("audiovideoswitch") else { return }
        let key = ObjectIdentifier(view)
        if videoStates[key] == nil {
            videoStates[key] = VideoState(view)
            writeDebugLog("[Karaoke][video] suppressed \(name)")
        }
        view.isHidden = true
        view.alpha = 0
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    private static var hasCachedLyrics: Bool {
        let tracker = KaraokePlaybackTracker.shared
        guard let track = tracker.playerReportedTrackId() ?? tracker.currentTrackId() else { return false }
        return KaraokeLyricsStore.shared.lyrics(forTrackId: track) != nil
    }

    static func resumePlayer(_ controller: UIViewController) {
        suspended = false
        preparingAppearance = false
        playerRoot = controller.viewIfLoaded
        loggedRoot = nil
        writeDebugLog("[Karaoke][lifecycle] Now Playing appeared; lyrics enabled=\(isEnabled)")
        restoreIfNeeded()
        if isPresented { layoutPlayer(controller); interact() }
    }

    private static func djPlayerRoot(_ controller: UIViewController) -> UIViewController {
        var result = controller
        var ancestor = controller.parent
        while let current = ancestor {
            let name = NSStringFromClass(type(of: current))
            if name.contains("NowPlaying") || name.contains("DJM") { result = current }
            ancestor = current.parent
        }
        return result
    }

    static func prepareDJPlayer(_ controller: UIViewController) {
        preparingAppearance = true
        suspended = false
        retryCount = 0
        let root = djPlayerRoot(controller)
        playerRoot = root.viewIfLoaded
        if isEnabled && UserDefaults.karaokeOptions.enabled && UserDefaults.lyricsSource.supportsCustomLyricsView {
            PlayerDeclutter.setLyricsOverride(true, in: playerRoot)
        }
        registerDJHead(controller)
        recoverNativeUnits(in: root)
        writeDebugLog("[Karaoke][DJ] preparing trackKnown=\(KaraokePlaybackTracker.shared.playerReportedTrackId() != nil)")
    }

    static func resumeDJPlayer(_ controller: UIViewController) {
        registerDJHead(controller)
        resumePlayer(djPlayerRoot(controller))
    }

    static func registerDJHead(_ controller: UIViewController) {
        guard let transport = controller.viewIfLoaded else { return }
        registerControls(transport)
        // DJ's head unit is the transport, not its Canvas. Keep lyrics outside the view that shrinks.
        let content = transport.superview?.superview
        let root = djPlayerRoot(controller).viewIfLoaded
        if let plane = content, plane.bounds.height > transport.bounds.height * 2 {
            registerCanvas(plane)
        } else if let root, root !== transport { registerCanvas(root) }
    }

    static func suspendDJPlayer(_ controller: UIViewController) {
        guard controls === controller.viewIfLoaded else { return }
        suspendPlayer()
    }

    static func suspendPlayer() {
        suspended = true
        preparingAppearance = false
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

    static func constrainedPlayerOffset(_ proposed: CGPoint, in scroll: UIScrollView) -> CGPoint {
        guard isPresented, outerScrolls[ObjectIdentifier(scroll)]?.view === scroll else { return proposed }
        return CGPoint(x: proposed.x, y: -scroll.adjustedContentInset.top)
    }

    private static func recoverNativeUnits(in controller: UIViewController) {
        guard let root = controller.viewIfLoaded else { return }
        var djControls: UIView?
        var pending = controller.children
        while let child = pending.popLast() {
            pending.append(contentsOf: child.children)
            guard let view = child.viewIfLoaded, view.isDescendant(of: root) else { continue }
            let name = NSStringFromClass(type(of: child))
            if name.contains("DJMHeadUnitViewController") { djControls = view }
            else if name.contains("PlaybackControlsElementsUnit") { registerControls(view) }
            else if name.contains("DurationElementUnit") || name.contains("DJMDurationElementsUnit") { registerDuration(view) }
            else if name.contains("InformationElementsUnit") || name.contains("DJMInformationUnit") { registerInformation(view) }
        }
        if let djControls { registerControls(djControls) }
    }

    static func layoutPlayer(_ controller: UIViewController) {
        guard let root = controller.viewIfLoaded else { return }
        playerRoot = root
        guard isPresented else { return }
        if controls?.window == nil || duration?.window == nil { recoverNativeUnits(in: controller) }
        if focused, controls?.window == nil || duration?.window == nil { interact() }
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
            if let unit = view.next as? UIViewController {
                let name = NSStringFromClass(type(of: unit))
                if name.contains("PlaybackControlsElementsUnit") || name.contains("DJMHeadUnitViewController"), controls !== view { registerControls(view) }
                else if name.contains("DurationElementUnit") || name.contains("DJMDurationElementsUnit"), duration !== view { registerDuration(view) }
            }
            suppressVideoSwitch(view)
            PlayerDeclutter.hideLatePlayerElement(view)
            queue.append(contentsOf: view.subviews)
            if let scroll = view as? UIScrollView,
               scroll.bounds.height > root.bounds.height * 0.5,
               scroll.contentSize.width <= scroll.bounds.width + 1,
               canvas?.isDescendant(of: scroll) == true {
                let id = ObjectIdentifier(scroll)
                if outerScrolls[id] == nil { outerScrolls[id] = ScrollState(view: scroll, enabled: scroll.isScrollEnabled, bounces: scroll.bounces) }
                scroll.isScrollEnabled = false
                scroll.bounces = false
                let top = -scroll.adjustedContentInset.top
                if abs(scroll.contentOffset.y - top) > 1 { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: top), animated: false) }
            }
        }
        for view in [controls, footer].compactMap({ $0 }) {
            let hidden = (focused || isLandscape) && view === footer && canHideFooter
            view.alpha = hidden ? 0 : 1
            view.isUserInteractionEnabled = !hidden
        }
        if focused { layoutCompactControls() }
        updateFrame()
    }

    static func interact(dragging: Bool = false) {
        idleWork?.cancel()
        setFocused(false)
        if isPresented {
            for view in [controls, footer].compactMap({ $0 }) {
                let hidden = isLandscape && view === footer && canHideFooter
                view.alpha = hidden ? 0 : 1; view.isUserInteractionEnabled = !hidden
            }
        }
        guard isPresented, isEnabled, !isLandscape, !dragging, !nativeTouchActive, !suspended else { return }
        let work = DispatchWorkItem {
            if isPresented && isEnabled && UIApplication.shared.applicationState == .active && !UIAccessibility.isVoiceOverRunning { setFocused(true) }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private static func layoutCompactControls() {
        guard focused, let controls, let canvas, let window = canvas.window,
              let saved = nativeStates[ObjectIdentifier(controls)] else { return }
        var parent: UIView? = controls
        var depth = 0
        while let view = parent, view !== playerRoot, view !== canvas, !(view is UIWindow), depth < 10 {
            pinCompactVisibility(view)
            parent = view.superview; depth += 1
        }
        if let row = controls.eeveeFirst(UIStackView.self, where: { $0.arrangedSubviews.count >= 3 }) { pinCompactVisibility(row) }
        controls.isUserInteractionEnabled = true
        let scale: CGFloat = 0.60
        let center = CGPoint(x: window.bounds.midX, y: window.safeAreaLayoutGuide.layoutFrame.maxY - 32)
        if let frame = unitFrame(controls, in: window),
           abs(frame.midX - center.x) < 1, abs(frame.midY - center.y) < 1,
           abs(controls.transform.a - saved.transform.a * scale) < 0.001,
           abs(controls.transform.d - saved.transform.d * scale) < 0.001 { return }
        objc_setAssociatedObject(controls, &compactTransformKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        controls.transform = saved.transform.scaledBy(x: scale, y: scale)
        guard let frame = unitFrame(controls, in: window) else { return }
        let delta = CGPoint(x: center.x - frame.midX, y: center.y - frame.midY)
        let moved = controls.superview?.convert(delta, from: window) ?? delta
        let zero = controls.superview?.convert(CGPoint.zero, from: window) ?? .zero
        var transform = controls.transform
        transform.tx += moved.x - zero.x
        transform.ty += moved.y - zero.y
        controls.transform = transform
        objc_setAssociatedObject(controls, &compactTransformKey, NSValue(cgAffineTransform: transform), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        controls.alpha = 1
        controls.isUserInteractionEnabled = true
    }

    private static func startFocusHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler {
            guard focused, isPresented, UIApplication.shared.applicationState == .active else { return }
            if let controller = playerRoot?.next as? UIViewController { layoutPlayer(controller) }
            else { layoutCompactControls(); refreshFocusGeometry() }
        }
        focusHeartbeat = timer
        timer.resume()
    }

    private static func setFocused(_ value: Bool) {
        guard !value || !isLandscape else { return }
        guard focused != value else { return }
        if value {
            if let controller = playerRoot?.next as? UIViewController { recoverNativeUnits(in: controller) }
            guard let window = canvas?.window, let controls, let duration, let information,
                  controls.window === window, duration.window === window, information.window === window,
                  let controlsFrame = unitFrame(controls, in: window), !controlsFrame.isEmpty,
                  let durationFrame = unitFrame(duration, in: window), !durationFrame.isEmpty else {
                if !waitingForNativeUnits { writeDebugLog("[Karaoke][focus] waiting for complete playback units; keeping normal layout") }
                waitingForNativeUnits = true
                let retry = DispatchWorkItem {
                    if isPresented && !suspended && !nativeTouchActive && !UIAccessibility.isVoiceOverRunning { setFocused(true) }
                }
                idleWork?.cancel(); idleWork = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: retry)
                return
            }
        }
        waitingForNativeUnits = false
        focusHeartbeat?.cancel()
        focusHeartbeat = nil
        releaseCompactVisibility()
        focused = value
        writeDebugLog("[Karaoke][focus] focused=\(value) positionMs=\(KaraokePlaybackTracker.shared.currentPositionMs()) info=\(String(describing: information?.frame)) controls=\(String(describing: controls?.frame))")
        if value, let canvas, let window = canvas.window, let information,
           let infoFrame = unitFrame(information, in: window), infoFrame.intersects(window.bounds) {
            for view in [information, duration, controls, footer].compactMap({ $0 }) {
                nativeStates[ObjectIdentifier(view)] = NativeState(view)
            }
            let end = duration.flatMap { unitFrame($0, in: window)?.maxY } ?? infoFrame.maxY
            focusShift = max(0, window.safeAreaLayoutGuide.layoutFrame.maxY - 66 - end)
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
                footer?.alpha = canHideFooter ? 0 : 1
                footer?.isUserInteractionEnabled = !canHideFooter
                layoutCompactControls()
                updateFrame()
            }
            startFocusHeartbeat()
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
        if focused, nativeStates[ObjectIdentifier(root)]?.view !== root { nativeStates[ObjectIdentifier(root)] = NativeState(root) }
        footer = root
        if isPresented {
            root.alpha = (focused || isLandscape) && canHideFooter ? 0 : 1
            root.isUserInteractionEnabled = !(focused || isLandscape) || !canHideFooter
        }
        restoreIfNeeded()
    }

    static func registerCanvas(_ root: UIView) {
        guard root.window != nil || preparingAppearance else { return }
        if canvas !== root, isPresented { removeHosting() }
        canvas = root
        if isPresented { updateFrame() } else { restoreIfNeeded() }
    }

    static func registerHeader(_ root: UIView) {
        header = root
        KaraokeLyricsSettingsMenu.register(root)
        if isPresented { updateFrame() } else { restoreIfNeeded() }
    }

    static func registerInformation(_ root: UIView) {
        if isPresented, let window = canvas?.window, root.window !== window { return }
        if focused, nativeStates[ObjectIdentifier(root)]?.view !== root { nativeStates[ObjectIdentifier(root)] = NativeState(root) }
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

    private static func planeFrame(in canvas: UIView) -> CGRect {
        guard isLandscape, let window = canvas.window else { return canvas.bounds }
        return canvas.convert(window.bounds, from: window)
    }

    private static func allowWideClipping(from view: UIView?) {
        var current = view
        while let item = current, !(item is UIWindow) {
            let id = ObjectIdentifier(item)
            if wideClipping[id]?.view !== item { wideClipping[id] = VideoState(item) }
            if item.clipsToBounds { item.clipsToBounds = false }
            current = item.superview
        }
    }

    static func beginNativeHeaderFrame(_ view: UIView) -> Bool {
        guard isPresented, positionedHeader === view, !changingHeaderFrame else { return false }
        changingHeaderFrame = true
        // UIKit's frame setter must see the natural transform, not yesterday's offset.
        if view.transform != headerBaseTransform { view.transform = headerBaseTransform }
        return true
    }

    static func endNativeHeaderFrame() {
        changingHeaderFrame = false
        updateFrame()
    }

    private static func applyHeaderGeometry() {
        guard let canvas, let window = canvas.window else { return }
        if positionedHeader !== header {
            positionedHeader?.transform = headerBaseTransform
            positionedHeader = header
            headerBaseTransform = header?.transform ?? .identity
        }
        guard let header, let parent = header.superview, let box = unitFrame(header, in: window) else { return }
        allowWideClipping(from: parent)
        let options = UserDefaults.karaokeOptions
        let offset = isLandscape ? options.landscapeHeaderOffset : options.portraitHeaderOffset
        let top = isLandscape ? window.bounds.minY : window.safeAreaLayoutGuide.layoutFrame.minY
        let correction = top + 8 + CGFloat(offset) - box.minY
        if abs(correction) > 0.25 {
            let origin = parent.convert(CGPoint.zero, from: window)
            let shifted = parent.convert(CGPoint(x: 0, y: correction), from: window)
            header.transform = header.transform.concatenating(CGAffineTransform(translationX: shifted.x - origin.x, y: shifted.y - origin.y))
        }
    }

    private static func restoreHeaderGeometry() {
        positionedHeader?.transform = headerBaseTransform
        positionedHeader = nil
    }

    private static func restoreWideGeometry() {
        let saved = wideClipping
        wideClipping.removeAll()
        for state in saved.values { state.view?.clipsToBounds = state.clips }
    }

    private static func landscapeFrames(in canvas: UIView) -> (sidebar: CGRect, lyrics: CGRect)? {
        guard let window = canvas.window, window.bounds.width > window.bounds.height else { return nil }
        let safe = window.safeAreaLayoutGuide.layoutFrame
        let headerBottom = header.flatMap { unitFrame($0, in: window)?.maxY } ?? safe.minY + 40
        let top = max(window.bounds.minY + 8, headerBottom + 6)
        let leading = max(window.bounds.minX + 14, safe.minX + 6)
        let body = CGRect(x: leading, y: top, width: max(1, window.bounds.maxX - leading - 14), height: max(1, safe.maxY - top - 8))
        let left = min(290, max(240, window.bounds.width * 0.29))
        let sidebar = CGRect(x: body.minX, y: body.minY, width: left, height: body.height)
        let lyrics = CGRect(x: sidebar.maxX + 20, y: body.minY, width: max(1, body.width - left - 20), height: body.height)
        func local(_ rect: CGRect) -> CGRect {
            let bounds = planeFrame(in: canvas)
            return canvas.convert(rect, from: window).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        }
        return (local(sidebar), local(lyrics))
    }

    private static func restoreLandscape() {
        guard let sidebar = landscapeSidebar else { return }
        landscapeSidebar = nil
        container?.sidebar = nil
        let wasUpdating = updatingFrame
        updatingFrame = true
        sidebar.restore()
        updatingFrame = wasUpdating
        footer?.alpha = 1; footer?.isUserInteractionEnabled = true
    }

    private static func lyricsFrame(in canvas: UIView) -> CGRect? {
        if let wide = landscapeFrames(in: canvas) { return wide.lyrics }
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
        let target = window.safeAreaLayoutGuide.layoutFrame.maxY - 66
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
        guard !updatingFrame else { return }
        updatingFrame = true
        defer { updatingFrame = false }
        if !isLandscape { restoreLandscape(); restoreWideGeometry() }
        if isLandscape { setFocused(false); allowWideClipping(from: canvas) }
        applyHeaderGeometry()
        refreshFocusGeometry()
        guard let canvas, let container, let hosting else { return }
        guard canvas.window != nil, let frame = lyricsFrame(in: canvas) else {
            container.isHidden = !preparingAppearance
            return
        }
        container.isHidden = false
        if let wide = landscapeFrames(in: canvas), let host = hosting.parent {
            let sidebar = landscapeSidebar ?? KaraokeLandscapeSidebar(frame: wide.sidebar, host: host)
            if landscapeSidebar == nil { landscapeSidebar = sidebar; container.addSubview(sidebar); container.sidebar = sidebar }
            if sidebar.frame != wide.sidebar { sidebar.frame = wide.sidebar }
            sidebar.attach(information, as: .information)
            sidebar.attach(duration, as: .duration)
            sidebar.attach(controls, as: .controls)
            sidebar.setNeedsLayout()
            sidebar.layoutIfNeeded()
            if canHideFooter { footer?.alpha = 0; footer?.isUserInteractionEnabled = false }
        }
        KaraokeRotation.update(controller: hosting.parent, enabled: isPresented)
        if viewport.landscape != isLandscape { viewport.landscape = isLandscape }
        let bounds = planeFrame(in: canvas)
        if container.frame != bounds { container.frame = bounds }
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
        guard !preparingAppearance else { return }
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
        guard !suspended, !mounting, isEnabled, UserDefaults.karaokeOptions.enabled,
              UserDefaults.lyricsSource.supportsCustomLyricsView, !isPresented else { return }
        // Cached content mounts synchronously, including while the native player is still offscreen.
        if hasCachedLyrics, show(animated: false, allowDetached: preparingAppearance) { return }
        guard !restoreScheduled else { return }
        restoreScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            restoreScheduled = false
            guard isEnabled, !isPresented, !suspended else { return }
            if !show(), retryCount < 4 {
                retryCount += 1
                restoreIfNeeded()
            }
        }
    }

    private static func preparationFrame(in canvas: UIView) -> CGRect? {
        guard canvas.bounds.width > 100, canvas.bounds.height > 200 else { return nil }
        let previous = viewport.frame
        let ratio = previous.width > 100 ? canvas.bounds.width / previous.width : 1
        let top = previous.height > 100 ? min(previous.minY * ratio, canvas.bounds.height * 0.35) : canvas.bounds.height * 0.13
        let bottom = previous.height > 100 ? min(canvas.bounds.height, previous.maxY * ratio) : canvas.bounds.height * 0.68
        guard bottom - top > 100 else { return nil }
        return CGRect(x: 0, y: top, width: canvas.bounds.width, height: bottom - top)
    }

    private static func show(animated: Bool = true, allowDetached: Bool = false) -> Bool {
        guard !mounting else { return false }
        dismissing = false
        _ = activityObserver
        if isPresented {
            container?.layer.removeAllAnimations()
            container?.alpha = 1
            interact()
            return true
        }
        guard #available(iOS 15.0, *), let canvas, canvas.window != nil || allowDetached,
              let frame = lyricsFrame(in: canvas) ?? (allowDetached ? preparationFrame(in: canvas) : nil), UserDefaults.karaokeOptions.enabled,
              UserDefaults.lyricsSource.supportsCustomLyricsView else { return false }
        if allowDetached, let playerRoot, !canvas.isDescendant(of: playerRoot) { return false }
        var responder: UIResponder? = canvas
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController else { return false }
        let tracker = KaraokePlaybackTracker.shared
        guard let trackId = tracker.playerReportedTrackId() ?? tracker.currentTrackId() else { return false }
        mounting = true
        defer { mounting = false }
        PlayerDeclutter.setLyricsOverride(true, in: playerRoot)
        viewport.frame = frame
        let child = UIHostingController(rootView: KaraokeLyricsView(trackId: trackId,
            lyrics: KaraokeLyricsStore.shared.lyrics(forTrackId: trackId), viewport: viewport, onDismiss: dismiss))
        if #available(iOS 16.4, *) { child.safeAreaRegions = [] }
        child.overrideUserInterfaceStyle = .dark
        child.view.backgroundColor = .clear
        let plane = KaraokeCanvasContainer(frame: canvas.bounds)
        plane.activeRect = frame
        plane.clipsToBounds = true
        plane.backgroundColor = .black
        controller.addChild(child)
        canvas.addSubview(plane)
        plane.addSubview(child.view)
        child.view.frame = plane.bounds
        child.didMove(toParent: controller)
        child.view.setNeedsLayout()
        child.view.layoutIfNeeded()
        plane.alpha = animated ? 0 : 1
        if animated { UIView.animate(withDuration: 0.25) { plane.alpha = 1 } }
        container = plane
        hosting = child
        isPresented = true
        retryCount = 0
        updateFrame()
        interact()
        if let controller = playerRoot?.next as? UIViewController { layoutPlayer(controller) }
        writeDebugLog("[Karaoke] Canvas replacement mounted; lyrics viewport \(frame) cached=\(!animated) detached=\(canvas.window == nil)")
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
        restoreLandscape()
        restoreHeaderGeometry()
        restoreWideGeometry()
        KaraokeRotation.update(controller: hosting?.parent, enabled: false)
        for saved in outerScrolls.values {
            saved.view?.isScrollEnabled = saved.enabled
            saved.view?.bounces = saved.bounces
        }
        outerScrolls.removeAll()
        isPresented = false
        PlayerDeclutter.setLyricsOverride(false, in: playerRoot)
        for saved in videoStates.values {
            saved.view?.isHidden = saved.hidden
            saved.view?.alpha = saved.alpha
            saved.view?.isUserInteractionEnabled = saved.interactive
            saved.view?.accessibilityElementsHidden = saved.accessibilityHidden
        }
        videoStates.removeAll()
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
    weak var sidebar: UIView?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        activeRect.contains(point) || sidebar?.frame.contains(point) == true
    }
}

/// Observe native sliders/buttons without delaying, cancelling, or recognizing their touches.
private final class KaraokeControlTouchMonitor: UIGestureRecognizer {
    private var trackingNative = false
    private var swipeStart: (point: CGPoint, band: CGRect)?
    private weak var swipeTouch: UITouch?
    private var samples: [(time: TimeInterval, y: CGFloat)] = []
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    private func sample(_ touch: UITouch) {
        samples.append((touch.timestamp, touch.location(in: nil).y))
        while samples.count > 2, samples[1].time < touch.timestamp - 0.12 { samples.removeFirst() }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !trackingNative, swipeStart == nil, let touch = touches.first else { return }
        if let start = KaraokeOverlayPresenter.dismissSwipeStart(touch) {
            swipeStart = start; swipeTouch = touch; sample(touch)
            return
        }
        guard KaraokeOverlayPresenter.nativeTouchBegan(touch) else { state = .failed; return }
        trackingNative = true
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = swipeTouch, touches.contains(touch) { sample(touch) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start = swipeStart, let touch = swipeTouch {
            guard touches.contains(touch) else { return }
            sample(touch)
            let first = samples.first!, last = samples.last!
            let speed = (last.y - first.y) / CGFloat(max(0.01, last.time - first.time))
            swipeStart = nil; swipeTouch = nil; samples.removeAll()
            KaraokeOverlayPresenter.finishDismissSwipe(start, touch: touch, speed: speed)
        }
        if trackingNative { KaraokeOverlayPresenter.nativeTouchEnded() }
        trackingNative = false; state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackingNative { KaraokeOverlayPresenter.nativeTouchEnded() }
        if swipeStart != nil { KaraokeOverlayPresenter.interact() }
        trackingNative = false; swipeStart = nil; swipeTouch = nil; samples.removeAll(); state = .failed
    }
    override func reset() {
        if trackingNative { KaraokeOverlayPresenter.nativeTouchEnded() }
        trackingNative = false; swipeStart = nil; swipeTouch = nil; samples.removeAll()
        super.reset()
    }
}
