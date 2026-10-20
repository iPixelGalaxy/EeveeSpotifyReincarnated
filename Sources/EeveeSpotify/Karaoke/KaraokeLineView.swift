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
    let timingOffsetMs: Int

    var onSeek: () -> Void
    @StateObject private var textCache = KaraokeTextPlanCache()

    private var singing: Bool { isActiveLine && currentMs >= layout.startMs && currentMs < layout.endMs }

    var body: some View {
        Group {
            if layout.isInterlude {
                KaraokeInterludeView(startMs: layout.startMs, endMs: layout.endMs,
                                     currentMs: currentMs, fontSize: fontSize)
                    .opacity(currentMs >= layout.startMs && currentMs < layout.endMs ? 1 : 0)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
                    .allowsHitTesting(false)
            } else {
                let plan = textCache.plan(words: layout.words, width: availableWidth, fontSize: fontSize,
                                          alignment: alignment, rtl: layout.isRTL,
                                          timingRange: layout.startMs...max(layout.startMs, layout.endMs))
                KaraokeShapedText(plan: plan, currentMs: currentMs, active: singing, timingOffsetMs: timingOffsetMs, onSeek: onSeek)
                    .frame(width: plan.drawingSize.width, height: plan.drawingSize.height)
                    .padding(.horizontal, -plan.horizontalGutter)
                    .padding(.vertical, -plan.verticalGutter)
                    .frame(width: availableWidth, height: plan.height)
            }
        }
        .frame(width: availableWidth)
        .opacity(singing ? 1 : (currentMs >= layout.endMs || distance < 0 ? 0.46 : 0.56))
        .blur(radius: singing ? 0 : min(1, CGFloat(abs(distance)) * CGFloat(blurIntensity) * 0.1))
        .animation(.easeInOut(duration: 0.3), value: singing)
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
        let glow = KaraokeAnimationCurve.interludeGlow(elapsed: Double(currentMs - startMs), duration: Double(endMs - startMs))
        HStack(spacing: fontSize * 0.4) {
            ForEach(0..<3) { index in
                let progress = min(1, max(0, (Double(currentMs - startMs) - Double(index) * duration) / duration))
                Circle()
                    .fill(Color.white)
                    .frame(width: fontSize * 0.5, height: fontSize * 0.5)
                    .opacity(Self.opacity.value(at: progress))
                    .scaleEffect(Self.scale.value(at: progress))
                    .offset(y: fontSize * Self.lift.value(at: progress))
            }
        }
        .shadow(color: .white.opacity(glow * 0.9), radius: 4 + 6 * glow)
        .padding(.vertical, 22)
        .frame(height: max(fontSize * 1.25, fontSize * 0.5 + 44))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Instrumental break"))
    }
}
