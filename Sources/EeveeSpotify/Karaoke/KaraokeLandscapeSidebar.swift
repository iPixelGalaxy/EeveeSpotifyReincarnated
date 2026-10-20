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

        init?(source: UIView, heightLimit: CGFloat) {
            let measured: CGFloat
            if source.bounds.height > heightLimit * 0.6,
               let stack = source.eeveeFirst(UIStackView.self, where: { !$0.isHidden && $0.bounds.height > 8 && $0.bounds.height < heightLimit * 0.6 }) {
                measured = stack.bounds.height
            } else { measured = source.bounds.height }
            guard source.bounds.width > 1, measured > 8, source.superview != nil else { return nil }
            self.source = source
            height = max(32, measured)
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
    private var applying = false
    private var restored = false
    private let artwork = UIImageView()
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
        refresh = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard #available(iOS 15.0, *), let self, let image = KaraokeBackgroundView.lastImage else { return }
            if self.artwork.image !== image { self.artwork.image = image }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ root: UIView?, as unit: Unit) {
        guard !restored, !applying, let root, window != nil, root.window === window else { return }
        guard placements[unit]?.source !== root else { return }
        applying = true
        defer { applying = false }
        // A retired unit is never inserted back into Spotify's hierarchy.
        let retired = placements.removeValue(forKey: unit)
        releaseRetiredVisibility()
        retired?.native.restore()
        guard let placement = Placement(source: root, heightLimit: max(200, bounds.height)) else { return }
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
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !restored, !applying else { return }
        applying = true
        defer { applying = false }
        let rows = Unit.allCases.compactMap { placements[$0] }.filter { $0.source?.window === window }
        let rowHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
        let gaps = CGFloat(rows.count) * 4 + 8
        let desiredArtwork = min(bounds.width - 8, bounds.height * 0.64)
        let scale = rowHeight > 0 ? min(0.65, max(0.45, (bounds.height - desiredArtwork - gaps) / rowHeight)) : 0.65
        let side = max(80, min(bounds.width - 8, bounds.height - rowHeight * scale - gaps))
        artwork.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
        var y = side + 8
        for row in rows {
            row.native.place(CGRect(x: 0, y: y, width: bounds.width, height: row.height * scale), in: self, scale: scale)
            if let view = row.view {
                row.geometry = Geometry(frame: view.frame, bounds: view.bounds, center: view.center, transform: view.transform)
            }
            y += row.height * scale + 4
        }
        contentSize = CGSize(width: bounds.width, height: y)
    }

    func restore() {
        restored = true
        refresh?.invalidate(); refresh = nil
        for unit in Unit.allCases.reversed() { placements.removeValue(forKey: unit)?.native.restore() }
        for state in visibility.values { state.restore() }
        visibility.removeAll()
        removeFromSuperview()
    }
    deinit { refresh?.invalidate() }
}
