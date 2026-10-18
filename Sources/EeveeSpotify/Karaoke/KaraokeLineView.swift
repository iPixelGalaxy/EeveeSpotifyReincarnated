import SwiftUI

struct KaraokeLineLayout {
    let words: [[KaraokeSyllableDto]]
    let isRTL: Bool
    let startMs: Int
    let endMs: Int
    let isInterlude: Bool
    let isOppositeAligned: Bool
    let isBackground: Bool
}

extension KaraokeTextAlignment {
    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .automatic, .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

@available(iOS 15.0, *)
struct KaraokeLineView: View {
    let layout: KaraokeLineLayout
    let currentMs: Int
    let isActiveLine: Bool
    let availableWidth: CGFloat
    let alignment: HorizontalAlignment
    let fontSize: CGFloat
    let distance: Int
    let isBrowsing: Bool
    let blurIntensity: Double

    var body: some View {
        Group {
            if layout.isInterlude {
                KaraokeInterludeView(startMs: layout.startMs, endMs: layout.endMs,
                                     currentMs: currentMs, fontSize: fontSize)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            } else {
                KaraokeFlowLayout(spacing: fontSize * 0.23, alignment: alignment) {
                    ForEach(Array(layout.words.enumerated()), id: \.offset) { _, word in
                        KaraokeWordView(syllables: word, currentMs: currentMs, isActiveLine: isActiveLine,
                                        isRTL: layout.isRTL, fontSize: fontSize)
                    }
                }
            }
        }
        .frame(width: availableWidth)
        .opacity(isActiveLine || isBrowsing ? 1.0 : (distance < 0 ? 0.46 : 0.56))
        .blur(radius: isActiveLine || isBrowsing ? 0 : min(4, CGFloat(abs(distance)) * CGFloat(blurIntensity) * 0.4))
        .scaleEffect(isActiveLine || isBrowsing ? 1.0 : 0.98, anchor: UnitPoint(x: alignment == .leading ? 0 : (alignment == .trailing ? 1 : 0.5), y: 0.5))
        .animation(.easeOut(duration: 0.35), value: isActiveLine)
        // Mirrors word/row order for RTL lines; the fill gradient is flipped separately below.
        .environment(\.layoutDirection, layout.isRTL ? .rightToLeft : .leftToRight)
    }
}

@available(iOS 15.0, *)
private struct KaraokeWordView: View {
    let syllables: [KaraokeSyllableDto]
    let currentMs: Int
    let isActiveLine: Bool
    let isRTL: Bool
    let fontSize: CGFloat
    @State private var motion = KaraokeWordMotion()

    private var startMs: Int { syllables.first?.startMs ?? 0 }
    private var endMs: Int { syllables.last?.endMs ?? startMs }
    private var letters: [Character] { Array(syllables.map(\.text).joined()) }
    // Match the plugin's default held-word threshold. Preserve joining scripts as shaped text.
    private var emphasizesLetters: Bool { !isRTL && endMs - startMs >= 1000 && letters.count > 1 }

    var body: some View {
        HStack(spacing: 0) {
            if emphasizesLetters {
                ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                    let sample = index < motion.letters.count ? motion.letters[index] : KaraokeMotionSample()
                    let duration = Double(max(1, endMs - startMs)) / Double(letters.count)
                    KaraokeLyricText(
                        text: String(letter),
                        progress: (Double(currentMs - startMs) - Double(index) * duration) / duration,
                        active: isActiveLine, isRTL: isRTL, fontSize: fontSize
                    )
                    .scaleEffect(sample.scale)
                    .offset(y: CGFloat(sample.offset * 2) * fontSize)
                    .shadow(color: .white.opacity(min(1, max(0, sample.glow * 1.85))), radius: CGFloat(4 + 12 * max(0, sample.glow)))
                }
            } else {
                ForEach(Array(syllables.enumerated()), id: \.offset) { _, syllable in
                    KaraokeLyricText(
                        text: syllable.text,
                        progress: syllable.endMs > syllable.startMs
                            ? Double(currentMs - syllable.startMs) / Double(syllable.endMs - syllable.startMs)
                            : (currentMs >= syllable.startMs ? 1 : 0),
                        active: isActiveLine, isRTL: isRTL, fontSize: fontSize
                    )
                }
            }
        }
        .scaleEffect(motion.word.scale)
        .offset(y: CGFloat(motion.word.offset) * fontSize)
        .shadow(color: .white.opacity(min(1, max(0, motion.word.glow))), radius: CGFloat(3 + 6 * max(0, motion.word.glow)))
        .onAppear { updateMotion() }
        .onChange(of: currentMs) { _ in updateMotion() }
        .onChange(of: isActiveLine) { _ in updateMotion() }
    }

    private func updateMotion() {
        motion.update(currentMs: currentMs, startMs: startMs, endMs: endMs,
                      letterCount: emphasizesLetters ? letters.count : 0,
                      active: isActiveLine, stamp: ProcessInfo.processInfo.systemUptime)
    }
}

@available(iOS 15.0, *)
private struct KaraokeLyricText: View {
    let text: String
    let progress: Double
    let active: Bool
    let isRTL: Bool
    let fontSize: CGFloat

    var body: some View {
        let progress = min(1, max(0, progress))
        // Plugin's sine-out wipe travels from -20% to 100%, with a soft transition band.
        let edge = -0.2 + 1.2 * sin(progress * .pi / 2)
        let left = min(1, max(0, edge - 0.1))
        let right = min(1, max(0, edge + 0.1))
        let bright = Color.white.opacity(active ? 0.85 : 1)
        let dim = Color.white.opacity(active ? 0.5 : 1)
        Text(text)
            .font(.system(size: fontSize, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(LinearGradient(stops: [
                .init(color: edge <= 0 ? dim : bright, location: 0),
                .init(color: edge <= 0 ? dim : bright, location: left),
                .init(color: edge >= 1 ? bright : dim, location: right),
                .init(color: edge >= 1 ? bright : dim, location: 1)
            ], startPoint: isRTL ? .trailing : .leading, endPoint: isRTL ? .leading : .trailing))
    }
}


@available(iOS 15.0, *)
private struct KaraokeInterludeView: View {
    let startMs: Int
    let endMs: Int
    let currentMs: Int
    let fontSize: CGFloat

    private static let scale = KaraokeAnimationCurve(points: [(0, 0.75), (0.7, 1.05), (1, 1)])
    private static let lift = KaraokeAnimationCurve(points: [(0, 0), (0.9, -0.12), (1, 0)])
    private static let opacity = KaraokeAnimationCurve(points: [(0, 0.35), (0.6, 1), (1, 1)])

    var body: some View {
        let duration = Double(max(1, endMs - startMs)) / 3
        HStack(spacing: fontSize * 0.22) {
            ForEach(0..<3) { index in
                let progress = min(1, max(0, (Double(currentMs - startMs) - Double(index) * duration) / duration))
                Circle()
                    .fill(Color.white)
                    .frame(width: fontSize * 0.26, height: fontSize * 0.26)
                    .scaleEffect(Self.scale.value(at: progress))
                    .offset(y: fontSize * Self.lift.value(at: progress))
                    .opacity(Self.opacity.value(at: progress))
                    .shadow(color: .white.opacity(progress > 0 && progress < 1 ? 0.45 : 0), radius: 6)
            }
        }
        .frame(height: fontSize * 1.25)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Instrumental break"))
    }
}
