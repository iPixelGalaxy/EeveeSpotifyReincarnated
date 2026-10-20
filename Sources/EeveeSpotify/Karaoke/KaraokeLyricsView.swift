import SwiftUI
import UIKit

final class KaraokeViewport: ObservableObject {
    @Published var frame = CGRect.zero
    @Published var landscape = false
}

@available(iOS 15.0, *)
struct KaraokeLyricsView: View {
    var onDismiss: () -> Void
    @ObservedObject private var viewport: KaraokeViewport
    @StateObject private var model: KaraokeLyricsViewModel
    @ObservedObject private var lyricFont = KaraokeFont.shared
    @State private var options = UserDefaults.karaokeOptions

    init(trackId: String?, lyrics: KaraokeLyricsDto?, viewport: KaraokeViewport, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.viewport = viewport
        _model = StateObject(wrappedValue: KaraokeLyricsViewModel(trackId: trackId, lyrics: lyrics))
    }

    var body: some View {
        GeometryReader { geo in
            let frame = viewport.frame.isEmpty ? CGRect(origin: .zero, size: geo.size) : viewport.frame
            ZStack(alignment: .topLeading) {
                KaraokeBackgroundView(trackId: model.trackId)
                LinearGradient(
                    colors: [.black.opacity(0.40), .black.opacity(0.32), .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                ZStack(alignment: .topTrailing) {
                    if let lyrics = model.lyrics {
                        content(lyrics: lyrics, layouts: model.layouts, size: frame.size)
                            // A new song starts from its own scroll position and state.
                            .id("\(model.trackId ?? ""):\(lyricFont.revision)")
                    } else {
                        VStack(spacing: 16) {
                            if model.loadingFailed {
                                Image(systemName: "mic.slash")
                                    .font(.system(size: 32))
                                Text("karaoke_loading_failed".localized)
                                    .multilineTextAlignment(.center)
                                Button("karaoke_retry".localized) { model.retry() }
                                    .buttonStyle(.bordered)
                            } else {
                                ProgressView()
                                    .tint(.white)
                                Text("karaoke_loading".localized)
                            }
                        }
                        .foregroundColor(.white)
                        .font(.system(size: 20.8))
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .clipped()
                .position(x: frame.midX, y: frame.midY)
            }
        }
        // UIKit already supplies a viewport in the Canvas view's coordinates.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { KaraokeOverlayPresenter.collapsePlayer() }
        .simultaneousGesture(DragGesture(minimumDistance: 20)
            .onChanged { _ in KaraokeOverlayPresenter.interact(dragging: true) }
            .onEnded { _ in KaraokeOverlayPresenter.interact() })
        .onAppear { lyricFont.configure(UserDefaults.karaokeOptions) }
        .onReceive(NotificationCenter.default.publisher(for: .eeveeKaraokeOptionsChanged)) { _ in
            let updated = UserDefaults.karaokeOptions
            lyricFont.configure(updated)
            if options != updated { options = updated }
            if !updated.enabled { onDismiss() }
        }
    }

    private var displayOptions: KaraokeOptions {
        var value = options
        if viewport.landscape { value.pinnedFooterMode = .off }
        return value
    }

    @ViewBuilder
    private func content(lyrics: KaraokeLyricsDto, layouts: [KaraokeLineLayout], size: CGSize) -> some View {
        if options.spaceGravityMode {
            KaraokeSpaceGravityView(lyrics: lyrics, layouts: layouts, options: displayOptions, size: size, showsCredits: !viewport.landscape)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                let currentMs = KaraokePlaybackTracker.shared.currentPositionMs() + Int(options.timingOffsetMs)

                KaraokeScrollingLines(
                    lyrics: lyrics,
                    layouts: layouts,
                    options: displayOptions,
                    currentMs: currentMs,
                    activeLineIndex: activeLineIndex(in: lyrics, at: currentMs),
                    size: size
                )
            }
        }
    }

    private func activeLineIndex(in lyrics: KaraokeLyricsDto, at currentMs: Int) -> Int? {
        guard !lyrics.lines.isEmpty else { return nil }
        for (index, line) in lyrics.lines.enumerated().reversed() {
            if currentMs >= line.startMs && !line.isBackground {
                return index
            }
        }
        return nil
    }


}

@available(iOS 15.0, *)
private struct KaraokeScrollingLines: View {
    let lyrics: KaraokeLyricsDto
    let layouts: [KaraokeLineLayout]
    let options: KaraokeOptions
    let currentMs: Int
    let activeLineIndex: Int?
    let size: CGSize

    private var scrollLineIndex: Int? {
        guard options.earlyScrolling else { return activeLineIndex }
        // Port the fork's separate scroll clock: look ahead without shifting syllable timing.
        // During a gap, prepare the next foreground line instead of holding the finished one.
        let lead = options.scrollLeadMs.isFinite ? min(800, max(0, options.scrollLeadMs)) : 250
        let clock = currentMs + Int(lead)
        let foreground = layouts.indices.filter { !layouts[$0].isBackground && !layouts[$0].isInterlude }
        return foreground.first { layouts[$0].startMs <= clock && clock < layouts[$0].endMs }
            ?? foreground.first { layouts[$0].startMs > clock }
            ?? foreground.last
    }

    @State private var isBrowsing = false
    @State private var isDragging = false
    @State private var resumeAt = Date.distantPast
    @State private var creditsAtBottom = false
    @State private var revealedCredits = false
    private let creditsID = "KaraokeCreditsEnd"
    private var lyricsEnded: Bool {
        guard options.pinnedFooterMode != .full, let end = layouts.map(\.endMs).max() else { return false }
        return currentMs >= end
    }
    @State private var creditsTopPadding: CGFloat = 0
    @State private var naturalContentHeight: CGFloat = .infinity
    @State private var pinnedCreditsHeight: CGFloat = 0
    private var viewportHeight: CGFloat {
        max(1, size.height - (options.pinnedFooterMode == .off ? 0 : pinnedCreditsHeight))
    }

    @ViewBuilder private var pinnedFooter: some View {
        if options.pinnedFooterMode != .off {
            KaraokeCreditsFooterView(lyrics: lyrics, showWriters: options.pinnedFooterMode == .full, unfaded: true)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: KaraokePinnedCreditsHeight.self, value: geometry.size.height)
                })
                .onPreferenceChange(KaraokePinnedCreditsHeight.self) { height in
                    if height.isFinite, abs(height - pinnedCreditsHeight) > 0.5 { pinnedCreditsHeight = height }
                }
        }
    }

    private var horizontalPadding: CGFloat { max(20, size.width * 0.05) }
    private var fontSize: CGFloat { 1.3 * CGFloat(KaraokeOptions.textScaleBaseline) * CGFloat(min(1.3, max(0.7, options.textScale))) * min(36, max(28, size.width * 0.075)) }
    @StateObject private var anchorLayout = KaraokeTextPlanCache()
    // Match LyricsVirtualizer.ts: 1 Hz, critically damped, preserving an interrupted glide.
    private var scrollAnimation: Animation {
        options.smoothScrolling && !UIAccessibility.isReduceMotionEnabled
            ? .interpolatingSpring(mass: 1, stiffness: 39.4784176, damping: 12.5663706)
            : .timingCurve(0.4, 0, 0, 1, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.65)
    }
    private var focus: UnitPoint {
        let lineHeight = KaraokeFont.shared.font(ofSize: fontSize).lineHeight + fontSize * 0.23
        var itemHeight = lineHeight
        if let index = scrollLineIndex, layouts.indices.contains(index) {
            let layout = layouts[index]
            if !layout.isInterlude {
                let alignment = options.textAlignment == .automatic
                    ? (layout.isOppositeAligned ? HorizontalAlignment.trailing : .leading) : options.textAlignment.horizontalAlignment
                itemHeight = anchorLayout.plan(words: layout.words, width: max(1, size.width - horizontalPadding * 2),
                    fontSize: fontSize, alignment: alignment, rtl: layout.isRTL).height
            }
        }
        // scrollTo aligns the same fraction of the item and viewport; account for both heights.
        let shift = lineHeight / max(lineHeight, viewportHeight - itemHeight)
        let y = options.reversedDirection ? 0.75 - shift : 0.25 + shift
        return UnitPoint(x: 0.5, y: min(0.95, max(0.05, y)))
    }

    var body: some View {
        let alignment = options.textAlignment.horizontalAlignment
        let flip: CGFloat = options.reversedDirection ? -1 : 1

        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: alignment, spacing: fontSize * 0.4) {
                        Color.clear.frame(height: viewportHeight * 0.25)

                        ForEach(Array(layouts.enumerated()).filter { entry in
                            !entry.element.isInterlude || (currentMs >= entry.element.startMs && currentMs < entry.element.endMs)
                        }, id: \.offset) { index, layout in
                            KaraokeLineView(
                                layout: layout,
                                currentMs: currentMs,
                                isActiveLine: index == activeLineIndex || (currentMs >= layout.startMs && currentMs < layout.endMs),
                                availableWidth: max(0, size.width - horizontalPadding * 2),
                                alignment: options.textAlignment == .automatic
                                    ? (layout.isOppositeAligned ? .trailing : .leading) : alignment,
                                fontSize: fontSize * (layout.isBackground ? 0.72 : 1),
                                distance: index - (activeLineIndex ?? 0),
                                isBrowsing: isBrowsing,
                                blurIntensity: options.blurIntensity,
                                timingOffsetMs: Int(options.timingOffsetMs),
                                onSeek: {
                                guard KaraokePlaybackTracker.shared.seek(toMs: max(0, layout.startMs - Int(options.timingOffsetMs))) else {
                                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                                    return
                                }
                                isBrowsing = false
                                isDragging = false
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.easeOut(duration: 0.35)) {
                                    proxy.scrollTo(index, anchor: focus)
                                }
                                }
                            )
                            .id(index)
                            .padding(.horizontal, horizontalPadding)
                            .scaleEffect(x: 1, y: flip)
                        }

                        if options.pinnedFooterMode != .full {
                            KaraokeCreditsFooterView(lyrics: lyrics, showDetails: options.pinnedFooterMode == .off, unfaded: creditsAtBottom, bottomPadding: 0)
                                .padding(.top, creditsTopPadding)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: KaraokeContentBottomKey.self,
                                        value: geometry.frame(in: .named("KaraokeLyricsContent")).maxY)
                                })
                                .scaleEffect(x: 1, y: flip)
                                .id(creditsID)
                        } else {
                            Color.clear.frame(height: max(fontSize * 1.1, viewportHeight * 0.65))
                        }

                    }
                    .frame(maxWidth: .infinity)
                    .background(KaraokeScrollLimits(atBottom: $creditsAtBottom))
                    .coordinateSpace(name: "KaraokeLyricsContent")
                }
                .frame(height: viewportHeight)
                .coordinateSpace(name: "KaraokeLyricsScroll")
                .onPreferenceChange(KaraokeContentBottomKey.self) { bottom in
                    guard bottom.isFinite, options.pinnedFooterMode != .full else { return }
                    // For short songs, fill above credits rather than leaving empty space below them.
                    naturalContentHeight = bottom - creditsTopPadding
                    let padding = max(0, viewportHeight - naturalContentHeight)
                    if abs(padding - creditsTopPadding) > 0.5 { creditsTopPadding = padding }
                }
                .onChange(of: viewportHeight) { height in
                    if naturalContentHeight.isFinite, options.pinnedFooterMode != .full { creditsTopPadding = max(0, height - naturalContentHeight) }
                    if !isBrowsing {
                        if lyricsEnded { proxy.scrollTo(creditsID, anchor: .bottom) }
                        else if let scrollLineIndex { proxy.scrollTo(scrollLineIndex, anchor: focus) }
                    }
                }
                .mask(
                    LinearGradient(stops: [
                        .init(color: creditsAtBottom && options.pinnedFooterMode != .full ? .black : .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.88),
                        .init(color: creditsAtBottom && options.pinnedFooterMode != .full ? .black : .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                )
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        KaraokeOverlayPresenter.interact(dragging: true)
                        isDragging = true
                        isBrowsing = true
                    }
                    .onEnded { _ in
                        KaraokeOverlayPresenter.interact()
                        isDragging = false
                        resumeAt = Date().addingTimeInterval(3)
                    }
                )
                .onAppear {
                    if lyricsEnded {
                        revealedCredits = true
                        proxy.scrollTo(creditsID, anchor: .bottom)
                    } else if let scrollLineIndex {
                        proxy.scrollTo(scrollLineIndex, anchor: focus)
                    }
                }
                .onChange(of: scrollLineIndex) { newIndex in
                    guard !isBrowsing, !lyricsEnded, let newIndex else { return }
                    withAnimation(scrollAnimation) {
                        proxy.scrollTo(newIndex, anchor: focus)
                    }
                }
                .onChange(of: currentMs) { _ in
                    if !lyricsEnded { revealedCredits = false }
                    if isBrowsing {
                        guard !isDragging, Date() >= resumeAt else { return }
                        isBrowsing = false
                        if lyricsEnded { revealedCredits = false }
                        else if let scrollLineIndex {
                            withAnimation(scrollAnimation) { proxy.scrollTo(scrollLineIndex, anchor: focus) }
                        }
                    }
                    if lyricsEnded, !revealedCredits, !isDragging {
                        revealedCredits = true
                        withAnimation(scrollAnimation) { proxy.scrollTo(creditsID, anchor: .bottom) }
                    }
                }
                // Flip the list and counter-flip rows; y-only so leading/trailing alignment isn't mirrored.
                .scaleEffect(x: 1, y: flip)
                pinnedFooter
            }
        }
        .environment(\.layoutDirection, lyrics.isRTL ? .rightToLeft : .leftToRight)
    }
}


private struct KaraokeContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Scope bounce changes to this lyrics scroll view, never to Spotify's global scroll appearance.
private struct KaraokeScrollLimits: UIViewRepresentable {
    @Binding var atBottom: Bool
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.onBottomChange = { bottom in if atBottom != bottom { atBottom = bottom } }
        view.configure()
    }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        private weak var attachedScroll: UIScrollView?
        var onBottomChange: ((Bool) -> Void)?
        private var observations = [NSKeyValueObservation]()
        private var lastBottom: Bool?

        private func publishBottom() {
            guard let scroll = attachedScroll, scroll.bounds.height > 0 else { return }
            let maximum = max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let bottom = scroll.contentOffset.y >= maximum - 2
            guard bottom != lastBottom else { return }
            lastBottom = bottom
            DispatchQueue.main.async { [weak self] in self?.onBottomChange?(bottom) }
        }
        private lazy var blankTap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(revealControls))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            return tap
        }()
        @objc private func revealControls() {
            writeDebugLog("[Karaoke][touch] blank tap; reveal controls")
            KaraokeOverlayPresenter.interact()
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let scroll = attachedScroll else { return false }
            return !KaraokeTextCanvas.visible.allObjects.contains { view in
                view.isDescendant(of: scroll) && view.containsInk(touch.location(in: view))
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UITapGestureRecognizer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); configure() }
        override func layoutSubviews() { super.layoutSubviews(); configure() }

        func configure() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.bounces = false
                    scroll.alwaysBounceVertical = false
                    scroll.contentInsetAdjustmentBehavior = .never
                    if scroll.contentInset.bottom != 0 {
                        var insets = scroll.contentInset; insets.bottom = 0; scroll.contentInset = insets
                    }
                    if attachedScroll !== scroll {
                        blankTap.view?.removeGestureRecognizer(blankTap)
                        attachedScroll = scroll
                        lastBottom = nil
                        observations = [
                            scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.publishBottom() },
                            scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.publishBottom() },
                            scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in self?.publishBottom() }
                        ]
                        scroll.addGestureRecognizer(blankTap)
                    }
                    publishBottom()
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct KaraokePinnedCreditsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
