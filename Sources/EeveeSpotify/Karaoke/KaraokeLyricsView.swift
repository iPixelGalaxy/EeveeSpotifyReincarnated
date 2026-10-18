import SwiftUI
import UIKit

final class KaraokeViewport: ObservableObject {
    @Published var frame = CGRect.zero
}

@available(iOS 15.0, *)
struct KaraokeLyricsView: View {
    var onDismiss: () -> Void
    @ObservedObject private var viewport: KaraokeViewport
    @StateObject private var model: KaraokeLyricsViewModel
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
                KaraokeBackgroundView()
                    .id(model.trackId)
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
                            .id(model.trackId)
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
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    closeButton
                }
                .frame(width: frame.width, height: frame.height)
                .clipped()
                .position(x: frame.midX, y: frame.midY)
            }
        }
        // UIKit already supplies a viewport in the Canvas view's coordinates.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .eeveeKaraokeOptionsChanged)) { _ in
            let updated = UserDefaults.karaokeOptions
            if options != updated { options = updated }
            if !updated.enabled { onDismiss() }
        }
    }

    private func content(lyrics: KaraokeLyricsDto, layouts: [KaraokeLineLayout], size: CGSize) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
            let currentMs = KaraokePlaybackTracker.shared.currentPositionMs()

            KaraokeScrollingLines(
                lyrics: lyrics,
                layouts: layouts,
                options: options,
                currentMs: currentMs,
                activeLineIndex: activeLineIndex(in: lyrics, at: currentMs),
                size: size
            )
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

    @ViewBuilder private var closeButtonBackground: some View {
        if KaraokeGlass.isEnabled {
            KaraokeGlassCapsule()
        } else {
            Circle().fill(Color.white.opacity(0.12))
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .padding(10)
                .background(closeButtonBackground)
        }
        .accessibilityLabel(Text("Close lyrics"))
        .padding(.top, 8)
        .padding(.trailing, 8)
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

    @State private var isBrowsing = false
    @State private var isDragging = false
    @State private var resumeAt = Date.distantPast
    @State private var creditsAtBottom = false
    @State private var creditsTopPadding: CGFloat = 0

    private var horizontalPadding: CGFloat { max(20, size.width * 0.05) }
    private var fontSize: CGFloat { min(36, max(28, size.width * 0.075)) }
    private var focus: UnitPoint { UnitPoint(x: 0.5, y: options.reversedDirection ? 0.75 : 0.25) }

    var body: some View {
        let alignment = options.textAlignment.horizontalAlignment
        let flip: CGFloat = options.reversedDirection ? -1 : 1

        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: alignment, spacing: fontSize * 0.4) {
                    Color.clear.frame(height: size.height * 0.25)

                    ForEach(Array(layouts.enumerated()), id: \.offset) { index, layout in
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
                            blurIntensity: options.blurIntensity
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard KaraokePlaybackTracker.shared.seek(toMs: layout.startMs) else {
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
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("Seek to this lyric"))
                        .id(index)
                        .padding(.horizontal, horizontalPadding)
                        .scaleEffect(x: 1, y: flip)
                    }

                    KaraokeCreditsFooterView(lyrics: lyrics)
                        .padding(.top, creditsTopPadding)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: KaraokeCreditsBottomKey.self,
                                value: geometry.frame(in: .named("KaraokeLyricsScroll")).maxY)
                                .preference(key: KaraokeContentBottomKey.self,
                                    value: geometry.frame(in: .named("KaraokeLyricsContent")).maxY)
                        })
                        .scaleEffect(x: 1, y: flip)

                }
                .frame(maxWidth: .infinity)
                .background(KaraokeScrollLimits())
                .coordinateSpace(name: "KaraokeLyricsContent")
            }
            .coordinateSpace(name: "KaraokeLyricsScroll")
            .onPreferenceChange(KaraokeCreditsBottomKey.self) { bottom in
                creditsAtBottom = bottom.isFinite && bottom <= size.height + 1
            }
            .onPreferenceChange(KaraokeContentBottomKey.self) { bottom in
                guard bottom.isFinite else { return }
                // For short songs, fill above credits rather than leaving empty space below them.
                let padding = max(0, size.height - (bottom - creditsTopPadding))
                if abs(padding - creditsTopPadding) > 0.5 { creditsTopPadding = padding }
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.88),
                    .init(color: creditsAtBottom ? .black : .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { _ in
                    isDragging = true
                    isBrowsing = true
                }
                .onEnded { _ in
                    isDragging = false
                    resumeAt = Date().addingTimeInterval(5)
                }
            )
            .onAppear {
                guard let activeLineIndex = activeLineIndex, activeLineIndex < lyrics.lines.count else { return }
                proxy.scrollTo(activeLineIndex, anchor: focus)
            }
            .onChange(of: activeLineIndex) { newIndex in
                guard !isBrowsing, let newIndex = newIndex, newIndex < lyrics.lines.count else { return }
                withAnimation(.timingCurve(0.4, 0, 0, 1, duration: 0.65)) {
                    proxy.scrollTo(newIndex, anchor: focus)
                }
            }
            .onChange(of: currentMs) { _ in
                guard isBrowsing, !isDragging, Date() >= resumeAt else { return }
                isBrowsing = false
                if let activeLineIndex = activeLineIndex {
                    withAnimation(.timingCurve(0.4, 0, 0, 1, duration: 0.65)) {
                        proxy.scrollTo(activeLineIndex, anchor: focus)
                    }
                }
            }
            // Flip the list and counter-flip rows; y-only so leading/trailing alignment isn't mirrored.
            .scaleEffect(x: 1, y: flip)
        }
        .environment(\.layoutDirection, lyrics.isRTL ? .rightToLeft : .leftToRight)
    }
}


private struct KaraokeCreditsBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct KaraokeContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Scope bounce changes to this lyrics scroll view, never to Spotify's global scroll appearance.
private struct KaraokeScrollLimits: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.configure() }

    final class Probe: UIView {
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
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
