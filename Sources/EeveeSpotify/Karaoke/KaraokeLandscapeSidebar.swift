import UIKit

/// Position Spotify's live units while preserving their view and controller ownership.
final class KaraokeLandscapeSidebar: UIScrollView {
    enum Unit: Int, CaseIterable { case information, duration, controls, dj }
    struct Geometry {
        let frame: CGRect
        let bounds: CGRect
        let center: CGPoint
        let transform: CGAffineTransform
    }
    private final class Placement {
        weak var source: UIView?
        let native: NativeViewPlacement
        let height: CGFloat
        var geometry: Geometry?
        var view: UIView? { native.view }

        init?(source: UIView, unit: Unit, heightLimit: CGFloat) {
            let measured: CGFloat
            if source.bounds.height > heightLimit * 0.6,
               let stack = source.eeveeFirst(UIStackView.self, where: { !$0.isHidden && $0.bounds.height > 8 && $0.bounds.height < heightLimit * 0.6 }) {
                measured = stack.bounds.height
            } else { measured = source.bounds.height }
            guard source.bounds.width > 1, measured > 8, source.superview != nil else { return nil }
            self.source = source
            // Native unit roots can still have fullscreen bounds on a landscape-first launch.
            // Budget for their actual role instead of treating those transient bounds as content.
            let limits: ClosedRange<CGFloat>
            switch unit {
            case .information: limits = 64...108
            case .duration: limits = 32...48
            case .controls: limits = 88...120
            case .dj: limits = 44...88
            }
            height = min(limits.upperBound, max(limits.lowerBound, measured))
            native = NativeViewPlacement(source)
        }
    }
    private struct ViewState {
        weak var view: UIView?
        let clips: Bool
        let alpha: CGFloat
        let hidden: Bool
        let interactive: Bool
        let accessibilityHidden: Bool
        var desiredClips: Bool
        init(_ view: UIView, clips: Bool) {
            self.view = view; self.clips = view.clipsToBounds; alpha = view.alpha
            hidden = view.isHidden; interactive = view.isUserInteractionEnabled
            accessibilityHidden = view.accessibilityElementsHidden; desiredClips = clips
        }
        func restore() {
            guard let view else { return }
            view.clipsToBounds = clips; view.alpha = alpha; view.isHidden = hidden
            view.isUserInteractionEnabled = interactive; view.accessibilityElementsHidden = accessibilityHidden
        }
    }
    private var visibility: [ObjectIdentifier: ViewState] = [:]
    private var placements: [Unit: Placement] = [:]
    private weak var informationArtwork: UIView?
    private var hiddenArtwork: [ObjectIdentifier: ViewState] = [:]
    private var applying = false
    private var restored = false
    private let artwork = UIImageView()
    private var canvasStage: UIView?
    private(set) var canvasActive = false
    private(set) var canvasControlsVisible = true
    private var canvasTouchActive = false
    private var canvasIdleWork: DispatchWorkItem?
    private var canvasButtons: [ObjectIdentifier: ViewState] = [:]
    var canvasIdle: Bool { canvasActive && !canvasControlsVisible }
    private var refresh: Timer?

    init(frame: CGRect, host: UIViewController) {
        super.init(frame: frame)
        showsVerticalScrollIndicator = false
        delaysContentTouches = false
        contentInsetAdjustmentBehavior = .never
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 10
        artwork.isAccessibilityElement = true
        artwork.accessibilityLabel = "karaoke_album_art".localized
        if #available(iOS 15.0, *), let image = KaraokeBackgroundView.lastImage { artwork.image = image }
        else { artwork.image = UIImage(systemName: "music.note") }
        artwork.tintColor = .white
        addSubview(artwork)
        if #available(iOS 15.0, *) {
            let stage = KaraokeCanvasStageView(frame: bounds)
            stage.visibilityChanged = { [weak self] visible in self?.setCanvasActive(visible) }
            insertSubview(stage, at: 0); canvasStage = stage
        }
        refresh = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard #available(iOS 15.0, *), let self else { return }
            (self.canvasStage as? KaraokeCanvasStageView)?.update()
            if let image = KaraokeBackgroundView.lastImage, self.artwork.image !== image { self.artwork.image = image }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setCanvasActive(_ active: Bool) {
        guard canvasActive != active else { return }
        canvasActive = active; canvasControlsVisible = !active
        canvasIdleWork?.cancel(); canvasTouchActive = false
        isScrollEnabled = !active
        artwork.isHidden = active
        if !active {
            canvasButtons.values.forEach { $0.restore() }; canvasButtons.removeAll()
        }
        setNeedsLayout()
        KaraokeOverlayPresenter.refreshCanvasChrome()
    }

    func beginCanvasInteraction() {
        guard canvasActive else { return }
        canvasTouchActive = true; canvasIdleWork?.cancel()
        setCanvasControlsVisible(true)
    }

    func endCanvasInteraction() {
        guard canvasActive else { return }
        canvasTouchActive = false; canvasIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.restored, self.canvasActive, !self.canvasTouchActive else { return }
            self.setCanvasControlsVisible(false)
        }
        canvasIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func setCanvasControlsVisible(_ visible: Bool) {
        guard canvasControlsVisible != visible else { return }
        canvasControlsVisible = visible
        UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            KaraokeOverlayPresenter.refreshCanvasChrome()
            self.setNeedsLayout(); self.layoutIfNeeded()
        }
    }

    private func updateCanvasButtons() {
        guard canvasActive, let root = placements[.information]?.view else { return }
        var candidates = root.subviews
        while let view = candidates.popLast() {
            let button = view is UIControl || view.accessibilityTraits.contains(.button)
            let hasText = (view as? UILabel)?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || view.eeveeFirst(UILabel.self, where: { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) != nil
            if button && !hasText {
                let key = ObjectIdentifier(view)
                if canvasButtons[key]?.view !== view { canvasButtons[key] = ViewState(view, clips: view.clipsToBounds) }
            } else { candidates += view.subviews }
        }
        for state in canvasButtons.values {
            state.view?.alpha = canvasIdle ? 0 : state.alpha
            state.view?.isUserInteractionEnabled = !canvasIdle && state.interactive
            state.view?.accessibilityElementsHidden = canvasIdle || state.accessibilityHidden
        }
    }

    func canvasAlpha(for view: UIView) -> CGFloat? {
        guard canvasIdle else { return nil }
        if canvasButtons[ObjectIdentifier(view)]?.view === view { return 0 }
        if [Unit.duration, .controls, .dj].contains(where: { placements[$0]?.view === view }) { return 0 }
        return nil
    }

    func attach(_ root: UIView?, as unit: Unit) {
        guard !restored, !applying, let root, window != nil, root.window === window else { return }
        if unit == .information { hideInformationArtwork(in: root) }
        guard placements[unit]?.source !== root else { return }
        applying = true
        defer { applying = false }
        // A retired unit is never inserted back into Spotify's hierarchy.
        let retired = placements.removeValue(forKey: unit)
        releaseRetiredVisibility()
        retired?.native.restore()
        guard let placement = Placement(source: root, unit: unit, heightLimit: max(200, bounds.height)) else { return }
        placements[unit] = placement
        if let view = placement.view { pinVisibility(view, clips: true) }
        var ancestor = placement.view?.superview
        while let view = ancestor, !(view is UIWindow), !isDescendant(of: view) {
            pinVisibility(view, clips: false)
            ancestor = view.superview
        }
        setNeedsLayout()
        writeDebugLog("[Karaoke][landscape] positioned \(unit), native ownership retained")
    }

    private func pinVisibility(_ view: UIView, clips: Bool) {
        let key = ObjectIdentifier(view)
        if visibility[key]?.view !== view { visibility[key] = ViewState(view, clips: clips) }
        visibility[key]?.desiredClips = clips
        view.alpha = 1; view.isHidden = false; view.isUserInteractionEnabled = true
        view.accessibilityElementsHidden = false; view.clipsToBounds = clips
    }

    private func hideInformationArtwork(in root: UIView) {
        guard informationArtwork?.isDescendant(of: root) != true else { return }
        let retired = hiddenArtwork
        hiddenArtwork.removeAll()
        for state in retired.values { state.restore() }
        guard let image = root.eeveeFirst(UIView.self, where: {
            NSStringFromClass(type(of: $0)).contains("ImageDataElementInput")
        }) else { informationArtwork = nil; return }
        informationArtwork = image
        var targets = [image]
        if let stack = image.superview as? UIStackView,
           let index = stack.arrangedSubviews.firstIndex(of: image), index + 1 < stack.arrangedSubviews.count {
            let spacer = stack.arrangedSubviews[index + 1]
            if spacer.subviews.isEmpty, spacer.bounds.height == 0, spacer.bounds.width <= 24 { targets.append(spacer) }
        }
        for view in targets {
            hiddenArtwork[ObjectIdentifier(view)] = ViewState(view, clips: view.clipsToBounds)
            view.isHidden = true
            view.accessibilityElementsHidden = true
        }
    }

    func hidesArtwork(_ view: UIView) -> Bool {
        !restored && hiddenArtwork[ObjectIdentifier(view)]?.view === view
    }

    private func releaseRetiredVisibility() {
        for (key, state) in visibility {
            let used = state.view.map { view in
                placements.values.contains { $0.source?.isDescendant(of: view) == true }
            } ?? false
            if !used {
                visibility.removeValue(forKey: key)
                state.restore()
            }
        }
    }

    func keepsVisible(_ view: UIView) -> Bool {
        !restored && visibility[ObjectIdentifier(view)]?.view === view
    }

    func requiredClipping(for view: UIView) -> Bool? {
        guard keepsVisible(view) else { return nil }
        return visibility[ObjectIdentifier(view)]?.desiredClips
    }

    func geometry(for view: UIView) -> Geometry? {
        guard !restored, !applying else { return nil }
        return placements.values.first(where: { $0.view === view && $0.source?.window === window })?.geometry
    }

    func nativeHit(at point: CGPoint, in window: UIWindow, event: UIEvent?) -> UIView? {
        guard convert(bounds, to: window).contains(point) else { return nil }
        for unit in [Unit.controls, .dj, .duration, .information] {
            if let row = placements[unit], row.source?.window === window, let view = row.view,
               let hit = NativeHitRouter.hit(view, at: point, in: window, event: event) { return hit }
        }
        return canvasActive ? self : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !restored, !applying else { return }
        canvasStage?.frame = bounds
        if #available(iOS 15.0, *), let window {
            KaraokeCanvasAmbient.shared.placeStage(beside: convert(bounds, to: window))
            (canvasStage as? KaraokeCanvasStageView)?.update()
        }
        applying = true
        defer { applying = false }
        let units = canvasIdle ? [Unit.information] : Unit.allCases
        let rows = units.compactMap { placements[$0] }.filter { $0.source?.window === window }
        let rowHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
        let gaps = CGFloat(rows.count) * 4 + 8
        let desiredArtwork = min(bounds.width - 8, bounds.height * 0.58)
        let scale = canvasActive ? CGFloat(0.65) : rowHeight > 0 ? min(0.65, max(0.45, (bounds.height - desiredArtwork - gaps) / rowHeight)) : 0.65
        // Keep the cover stable while units arrive; overflow remains scrollable in this sidebar.
        let side = max(80, desiredArtwork)
        artwork.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
        var y = canvasActive ? max(0, bounds.height - rowHeight * scale - gaps) : side + 8
        for unit in [Unit.duration, .controls, .dj] {
            placements[unit]?.view?.alpha = canvasIdle ? 0 : 1
            placements[unit]?.view?.isUserInteractionEnabled = !canvasIdle
            placements[unit]?.view?.accessibilityElementsHidden = canvasIdle
        }
        updateCanvasButtons()
        for row in rows {
            row.native.place(CGRect(x: 0, y: y, width: bounds.width, height: row.height * scale), in: self, scale: scale)
            if let view = row.view {
                row.geometry = Geometry(frame: view.frame, bounds: view.bounds, center: view.center, transform: view.transform)
            }
            y += row.height * scale + 4
        }
        contentSize = CGSize(width: bounds.width, height: canvasActive ? bounds.height : y)
        if canvasActive, contentOffset != .zero { contentOffset = .zero }
    }

    func restore() {
        restored = true
        setCanvasActive(false); canvasIdleWork?.cancel()
        if #available(iOS 15.0, *) { (canvasStage as? KaraokeCanvasStageView)?.stop() }
        refresh?.invalidate(); refresh = nil
        for state in hiddenArtwork.values { state.restore() }
        hiddenArtwork.removeAll(); informationArtwork = nil
        for unit in Unit.allCases.reversed() { placements.removeValue(forKey: unit)?.native.restore() }
        for state in visibility.values { state.restore() }
        visibility.removeAll()
        removeFromSuperview()
    }
    deinit { refresh?.invalidate() }
}
