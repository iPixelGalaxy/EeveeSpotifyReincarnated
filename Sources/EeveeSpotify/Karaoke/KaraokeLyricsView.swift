import SwiftUI

@available(iOS 15.0, *)
struct KaraokeLyricsView: View {
    var onDismiss: () -> Void
    @StateObject private var model: KaraokeLyricsViewModel
    private let options = UserDefaults.karaokeOptions

    init(trackId: String?, lyrics: KaraokeLyricsDto?, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _model = StateObject(wrappedValue: KaraokeLyricsViewModel(trackId: trackId, lyrics: lyrics))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                KaraokeBackgroundView()
                    .id(model.trackId)
                LinearGradient(
                    colors: [.black.opacity(0.40), .black.opacity(0.32), .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                if let lyrics = model.lyrics {
                    content(lyrics: lyrics, layouts: model.layouts, size: geo.size)
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
        }
        .preferredColorScheme(.dark)
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
            if currentMs >= line.startMs {
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

    private var horizontalPadding: CGFloat { max(20, size.width * 0.05) }
    private var fontSize: CGFloat { min(56, max(29.6, size.width * 0.07)) * 1.75 }
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
                            isActiveLine: index == activeLineIndex,
                            availableWidth: max(0, size.width - horizontalPadding * 2),
                            alignment: alignment,
                            fontSize: fontSize,
                            distance: index - (activeLineIndex ?? 0),
                            isBrowsing: isBrowsing,
                            blurIntensity: options.blurIntensity
                        )
                        .id(index)
                        .padding(.horizontal, horizontalPadding)
                        .scaleEffect(x: 1, y: flip)
                    }

                    KaraokeCreditsFooterView(lyrics: lyrics)
                        .scaleEffect(x: 1, y: flip)

                    Color.clear.frame(height: size.height * 0.75)
                }
                .frame(maxWidth: .infinity)
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1)
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
