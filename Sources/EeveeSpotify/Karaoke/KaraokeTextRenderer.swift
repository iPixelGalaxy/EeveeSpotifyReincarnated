import SwiftUI
import UIKit
import CoreText

/// Shape a complete paragraph once. Animation never changes glyph advances or wrapping.
final class KaraokeTextPlan {
    struct Segment {
        let range: NSRange
        let timing: KaraokeSyllableDto
        var glyphs: [Int] = []
        var bounds = CGRect.null
    }
    struct Glyph {
        let font: CTFont
        let value: CGGlyph
        let path: CGPath?
        let position: CGPoint
        let bounds: CGRect
        let advance: CGFloat
        let stringIndex: Int
        let segment: Int
        let rtl: Bool
        var rank = 0
        var fraction: CGFloat = 0
        var share: CGFloat = 1
    }
    let frame: CTFrame
    let height: CGFloat
    let fontSize: CGFloat
    let text: String
    var segments: [Segment]
    var glyphs: [Glyph] = []

    init(words: [[KaraokeSyllableDto]], width: CGFloat, fontSize: CGFloat, alignment: HorizontalAlignment, rtl: Bool) {
        self.fontSize = fontSize
        var text = ""
        var segments: [Segment] = []
        for word in words {
            let parts = word.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !parts.isEmpty else { continue }
            if !text.isEmpty { text += " " }
            for part in parts {
                let fragment = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let range = NSRange(location: text.utf16.count, length: fragment.utf16.count)
                text += fragment
                segments.append(Segment(range: range, timing: part))
            }
        }
        self.text = text
        self.segments = segments
        let style = NSMutableParagraphStyle()
        style.alignment = alignment == .trailing ? .right : (alignment == .center ? .center : .left)
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = fontSize * 0.23
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.white, .paragraphStyle: style
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let fitting = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(1, width), height: .greatestFiniteMagnitude), nil)
        height = max(1, ceil(fitting.height) + 2)
        frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 0, y: 0, width: max(1, width), height: height), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (lineIndex, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont
                var values = Array(repeating: CGGlyph(0), count: count)
                var positions = Array(repeating: CGPoint.zero, count: count)
                var advances = Array(repeating: CGSize.zero, count: count)
                var indices = Array(repeating: CFIndex(0), count: count)
                let range = CFRange(location: 0, length: 0)
                CTRunGetGlyphs(run, range, &values)
                CTRunGetPositions(run, range, &positions)
                CTRunGetAdvances(run, range, &advances)
                CTRunGetStringIndices(run, range, &indices)
                for index in 0..<count {
                    guard let segment = segments.firstIndex(where: { NSLocationInRange(indices[index], $0.range) }) else { continue }
                    var value = values[index]
                    var bounds = CGRect.zero
                    CTFontGetBoundingRectsForGlyphs(font, .default, &value, &bounds, 1)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let point = CGPoint(x: origins[lineIndex].x + positions[index].x, y: origins[lineIndex].y + positions[index].y)
                    let glyph = Glyph(font: font, value: value, path: CTFontCreatePathForGlyph(font, value, nil),
                        position: point, bounds: bounds, advance: max(0, advances[index].width),
                        stringIndex: indices[index], segment: segment, rtl: CTRunGetStatus(run).contains(.rightToLeft))
                    self.segments[segment].glyphs.append(glyphs.count)
                    self.segments[segment].bounds = self.segments[segment].bounds.union(bounds.offsetBy(dx: point.x, dy: point.y))
                    glyphs.append(glyph)
                }
            }
        }
        for segment in self.segments.indices {
            let ordered = self.segments[segment].glyphs.sorted { glyphs[$0].stringIndex < glyphs[$1].stringIndex }
            let total = max(1, ordered.reduce(CGFloat.zero) { $0 + glyphs[$1].advance })
            var offset: CGFloat = 0
            for (rank, index) in ordered.enumerated() {
                glyphs[index].rank = rank
                glyphs[index].fraction = offset / total
                glyphs[index].share = max(0.001, glyphs[index].advance / total)
                offset += glyphs[index].advance
            }
        }
    }
}

final class KaraokeTextPlanCache: ObservableObject {
    private var key = ""
    private var stored: KaraokeTextPlan?
    func plan(words: [[KaraokeSyllableDto]], width: CGFloat, fontSize: CGFloat, alignment: HorizontalAlignment, rtl: Bool) -> KaraokeTextPlan {
        let signature = "\(width)|\(fontSize)|\(alignment)|\(rtl)|" + words.map { word in
            word.map { "\($0.text):\($0.startMs):\($0.endMs)" }.joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        if signature == key, let stored { return stored }
        let plan = KaraokeTextPlan(words: words, width: width, fontSize: fontSize, alignment: alignment, rtl: rtl)
        key = signature
        stored = plan
        return plan
    }
}

struct KaraokeShapedText: UIViewRepresentable {
    let plan: KaraokeTextPlan
    let currentMs: Int
    let active: Bool
    let onSeek: () -> Void
    func makeUIView(context: Context) -> KaraokeTextCanvas { KaraokeTextCanvas() }
    func updateUIView(_ view: KaraokeTextCanvas, context: Context) { view.update(plan: plan, currentMs: currentMs, active: active, onSeek: onSeek) }
}

final class KaraokeTextCanvas: UIView {
    static let visible = NSHashTable<KaraokeTextCanvas>.weakObjects()
    private var plan: KaraokeTextPlan?
    private var currentMs = 0
    private var active = false
    private var motions: [KaraokeWordMotion] = []
    private var onSeek: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(seek)))
        Self.visible.add(self)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Seek to this lyric"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func seek() { onSeek?() }

    func update(plan: KaraokeTextPlan, currentMs: Int, active: Bool, onSeek: @escaping () -> Void) {
        let changed = self.plan !== plan || self.active != active
        if self.plan !== plan {
            motions = plan.segments.map { _ in KaraokeWordMotion() }
            accessibilityLabel = plan.text
        }
        self.plan = plan
        self.currentMs = currentMs
        self.active = active
        self.onSeek = onSeek
        if active {
            let stamp = ProcessInfo.processInfo.systemUptime
            for index in plan.segments.indices {
                let part = plan.segments[index]
                motions[index].update(currentMs: currentMs, startMs: part.timing.startMs, endMs: part.timing.endMs,
                    letterCount: part.timing.endMs - part.timing.startMs >= 1000 ? part.glyphs.count : 0, active: true, stamp: stamp)
            }
        }
        if changed || active { setNeedsDisplay() }
    }

    private func transform(for glyph: KaraokeTextPlan.Glyph, in plan: KaraokeTextPlan) -> (CGAffineTransform, KaraokeMotionSample) {
        guard active, glyph.segment < motions.count else { return (.init(translationX: glyph.position.x, y: glyph.position.y), KaraokeMotionSample()) }
        let motion = motions[glyph.segment]
        let letter = glyph.rank < motion.letters.count
        let sample = letter ? motion.letters[glyph.rank] : motion.word
        let center = letter ? glyph.position.x + glyph.bounds.midX : plan.segments[glyph.segment].bounds.midX
        let scale = CGFloat(sample.scale)
        let matrix = CGAffineTransform(translationX: center, y: glyph.position.y - CGFloat(sample.offset) * plan.fontSize * (letter ? 2 : 1))
            .scaledBy(x: scale, y: scale).translatedBy(x: glyph.position.x - center, y: 0)
        return (matrix, sample)
    }

    func containsInk(_ point: CGPoint) -> Bool {
        guard let plan, bounds.contains(point) else { return false }
        return plan.glyphs.contains { glyph in
            let box = glyph.bounds.applying(transform(for: glyph, in: plan).0)
            let ui = CGRect(x: box.minX, y: plan.height - box.maxY, width: box.width, height: box.height)
            return ui.insetBy(dx: -1.5, dy: -1.5).contains(point)
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { containsInk(point) }
    override func accessibilityActivate() -> Bool { onSeek?(); return true }

    override func draw(_ rect: CGRect) {
        guard let plan, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: 0, y: plan.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        if !active { CTFrameDraw(plan.frame, context); context.restoreGState(); return }
        for glyph in plan.glyphs {
            let part = plan.segments[glyph.segment]
            let progress = min(1, max(0, Double(currentMs - part.timing.startMs) / Double(max(1, part.timing.endMs - part.timing.startMs))))
            let local = (CGFloat(progress) - glyph.fraction) / glyph.share
            let edge = min(1.2, max(-0.2, local))
            let (matrix, sample) = transform(for: glyph, in: plan)
            context.saveGState()
            context.concatenate(matrix)
            if let path = glyph.path {
                if sample.glow > 0.01 {
                    context.setShadow(offset: .zero, blur: CGFloat(4 + 10 * sample.glow), color: UIColor.white.withAlphaComponent(min(0.55, sample.glow * 0.55)).cgColor)
                    context.setFillColor(UIColor.white.withAlphaComponent(0.3).cgColor)
                    context.addPath(path); context.fillPath()
                    context.setShadow(offset: .zero, blur: 0, color: nil)
                }
                context.addPath(path); context.clip()
                let dim = UIColor.white.withAlphaComponent(0.50).cgColor
                let bright = UIColor.white.withAlphaComponent(0.95).cgColor
                let colors = [edge <= 0 ? dim : bright, edge <= 0 ? dim : bright, edge >= 1 ? bright : dim, edge >= 1 ? bright : dim]
                let locations: [CGFloat] = [0, max(0, min(1, edge - 0.1)), max(0, min(1, edge + 0.1)), 1]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations) {
                    let start = CGPoint(x: glyph.rtl ? glyph.bounds.maxX : glyph.bounds.minX, y: 0)
                    let end = CGPoint(x: glyph.rtl ? glyph.bounds.minX : glyph.bounds.maxX, y: 0)
                    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            } else {
                var value = glyph.value
                var zero = CGPoint.zero
                context.setFillColor(UIColor.white.withAlphaComponent(progress > 0 ? 0.95 : 0.5).cgColor)
                CTFontDrawGlyphs(glyph.font, &value, &zero, 1, context)
            }
            context.restoreGState()
        }
        context.restoreGState()
    }
}
