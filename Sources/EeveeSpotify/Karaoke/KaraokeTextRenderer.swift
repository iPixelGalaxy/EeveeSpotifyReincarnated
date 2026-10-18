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
    let rtl: Bool
    let text: String
    let inkColor: UIColor
    let dimInk: CGColor
    let brightInk: CGColor
    let glowInk: CGColor
    let highlightGradient: CGGradient?
    private static let gradientSpace = CGColorSpaceCreateDeviceRGB()
    var segments: [Segment]
    var glyphs: [Glyph] = []

    init(words: [[KaraokeSyllableDto]], width: CGFloat, fontSize: CGFloat, alignment: HorizontalAlignment, rtl: Bool, inkColor: UIColor = .white) {
        self.inkColor = inkColor
        let dim = inkColor.withAlphaComponent(0.50).cgColor
        let bright = inkColor.withAlphaComponent(0.95).cgColor
        dimInk = dim
        brightInk = bright
        glowInk = inkColor.withAlphaComponent(0.3).cgColor
        highlightGradient = CGGradient(colorsSpace: Self.gradientSpace, colors: [bright, dim] as CFArray, locations: [0, 1])
        self.fontSize = fontSize
        self.rtl = rtl
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
        style.alignment = alignment == .center ? .center :
            (alignment == .trailing ? (rtl ? .left : .right) : (rtl ? .right : .left))
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = fontSize * 0.23
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: inkColor, .paragraphStyle: style
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
    private struct Key: Equatable {
        let words: [[KaraokeSyllableDto]]
        let width: CGFloat
        let fontSize: CGFloat
        let alignment: HorizontalAlignment
        let rtl: Bool
    }
    private var key: Key?
    private var stored: KaraokeTextPlan?
    func plan(words: [[KaraokeSyllableDto]], width: CGFloat, fontSize: CGFloat, alignment: HorizontalAlignment, rtl: Bool) -> KaraokeTextPlan {
        let next = Key(words: words, width: width, fontSize: fontSize, alignment: alignment, rtl: rtl)
        if key == next, let stored { return stored }
        let plan = KaraokeTextPlan(words: words, width: width, fontSize: fontSize, alignment: alignment, rtl: rtl)
        key = next
        stored = plan
        return plan
    }
}

struct KaraokeShapedText: UIViewRepresentable {
    let plan: KaraokeTextPlan
    let currentMs: Int
    let active: Bool
    let timingOffsetMs: Int
    let onSeek: () -> Void
    func makeUIView(context: Context) -> KaraokeTextCanvas { KaraokeTextCanvas() }
    func updateUIView(_ view: KaraokeTextCanvas, context: Context) { view.update(plan: plan, currentMs: currentMs, active: active, usesPlaybackClock: true, timingOffsetMs: timingOffsetMs, onSeek: onSeek) }
}

final class KaraokeTextCanvas: UIView {
    static let visible = NSHashTable<KaraokeTextCanvas>.weakObjects()
    private var plan: KaraokeTextPlan?
    private var currentMs = 0
    private var active = false
    private var motions: [KaraokeWordMotion] = []
    private var onSeek: (() -> Void)?
    private var usesPlaybackClock = false
    private var timingOffsetMs = 0
    private var displayLink: CADisplayLink?

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
    deinit { displayLink?.invalidate() }
    @objc private func seek() { onSeek?() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateDisplayLink()
    }

    func update(plan: KaraokeTextPlan, currentMs: Int, active: Bool, usesPlaybackClock: Bool = false,
                timingOffsetMs: Int = 0, onSeek: @escaping () -> Void) {
        let changed = self.plan !== plan || self.active != active
        if self.plan !== plan {
            motions = plan.segments.map { _ in KaraokeWordMotion() }
            accessibilityLabel = plan.text
        }
        self.plan = plan
        self.active = active
        self.onSeek = onSeek
        self.usesPlaybackClock = usesPlaybackClock
        self.timingOffsetMs = timingOffsetMs
        // SwiftUI handles line transitions; UIKit advances highlights on the display clock.
        // Read the live clock here too, so a delayed SwiftUI update cannot rewind a frame.
        let position = usesPlaybackClock ? KaraokePlaybackTracker.shared.currentPositionMs() + timingOffsetMs : currentMs
        updateMotion(at: position)
        updateDisplayLink()
        if changed || active { setNeedsDisplay() }
    }

    private func updateMotion(at position: Int) {
        currentMs = position
        guard let plan else { return }
        if active {
            let stamp = ProcessInfo.processInfo.systemUptime
            for index in plan.segments.indices {
                let part = plan.segments[index]
                motions[index].update(currentMs: position, startMs: part.timing.startMs, endMs: part.timing.endMs,
                    letterCount: !plan.rtl && part.timing.endMs - part.timing.startMs >= 1000 ? part.glyphs.count : 0, active: true, stamp: stamp)
            }
        }
    }

    private var canAnimate: Bool {
        guard usesPlaybackClock, active, let window, bounds.width > 0, bounds.height > 0,
              convert(bounds, to: window).intersects(window.bounds) else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha <= 0.01 { return false }
            view = current.superview
        }
        return true
    }
    private func updateDisplayLink() {
        guard canAnimate else {
            displayLink?.invalidate(); displayLink = nil
            return
        }
        guard displayLink == nil else { return }
        let relay = KaraokeTextDisplayTick(canvas: self)
        let link = CADisplayLink(target: relay, selector: #selector(KaraokeTextDisplayTick.tick(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    fileprivate func displayTick() {
        guard canAnimate else { updateDisplayLink(); return }
        updateMotion(at: KaraokePlaybackTracker.shared.currentPositionMs() + timingOffsetMs)
        setNeedsDisplay()
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
                    context.setShadow(offset: .zero, blur: CGFloat(4 + 10 * sample.glow), color: plan.inkColor.withAlphaComponent(min(0.55, sample.glow * 0.55)).cgColor)
                    context.setFillColor(plan.glowInk)
                    context.addPath(path); context.fillPath()
                    context.setShadow(offset: .zero, blur: 0, color: nil)
                }
                context.addPath(path); context.clip()
                if edge <= 0 || edge >= 1 {
                    context.setFillColor(edge <= 0 ? plan.dimInk : plan.brightInk)
                    context.fill(glyph.bounds.insetBy(dx: -1, dy: -1))
                } else if let gradient = plan.highlightGradient {
                    let origin = glyph.rtl ? glyph.bounds.maxX : glyph.bounds.minX
                    let span = glyph.rtl ? -glyph.bounds.width : glyph.bounds.width
                    let start = CGPoint(x: origin + span * CGFloat(max(0, edge - 0.1)), y: 0)
                    let end = CGPoint(x: origin + span * CGFloat(min(1, edge + 0.1)), y: 0)
                    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            } else {
                var value = glyph.value
                var zero = CGPoint.zero
                context.setFillColor(progress > 0 ? plan.brightInk : plan.dimInk)
                CTFontDrawGlyphs(glyph.font, &value, &zero, 1, context)
            }
            context.restoreGState()
        }
        context.restoreGState()
    }
}

private final class KaraokeTextDisplayTick: NSObject {
    weak var canvas: KaraokeTextCanvas?
    init(canvas: KaraokeTextCanvas) { self.canvas = canvas; super.init() }
    @objc func tick(_ link: CADisplayLink) { canvas?.displayTick() }
}
