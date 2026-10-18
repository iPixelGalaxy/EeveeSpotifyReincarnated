import SwiftUI
import UIKit
import CoreText

/// Shape a complete paragraph once. Animation never changes glyph advances or wrapping.
final class KaraokeTextPlan {
    struct Segment {
        let range: NSRange
        let timing: KaraokeSyllableDto
        let highlightStartMs: Int
        let highlightEndMs: Int
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
    let layoutWidth: CGFloat
    private(set) var inkBounds = CGRect.null
    var horizontalGutter: CGFloat {
        max(24, ceil(fontSize * 0.35 + 18 + max(0, max(-inkBounds.minX, inkBounds.maxX - layoutWidth))))
    }
    var verticalGutter: CGFloat {
        max(24, ceil(fontSize * 0.35 + 18 + max(0, max(-inkBounds.minY, inkBounds.maxY - height))))
    }
    var drawingSize: CGSize { CGSize(width: layoutWidth + 2 * horizontalGutter, height: height + 2 * verticalGutter) }
    var collisionRadius: CGFloat {
        let x = max(abs(inkBounds.minX - layoutWidth / 2), abs(inkBounds.maxX - layoutWidth / 2))
        let y = max(abs(inkBounds.minY - height / 2), abs(inkBounds.maxY - height / 2))
        return max(14, hypot(x, y) + fontSize * 0.2 + 14)
    }
    let rtl: Bool
    let text: String
    let inkColor: UIColor
    let baseInk: CGColor
    let fillInks: [CGColor]
    let glowInks: [CGColor]
    let startMs: Int
    let endMs: Int
    var segments: [Segment]
    var glyphs: [Glyph] = []

    init(words: [[KaraokeSyllableDto]], width: CGFloat, fontSize: CGFloat, alignment: HorizontalAlignment, rtl: Bool, inkColor: UIColor = .white,
         timingRange: ClosedRange<Int>? = nil, isInterlude: Bool = false) {
        self.inkColor = inkColor
        baseInk = inkColor.cgColor
        let dotOpacity = KaraokeAnimationCurve(points: [(0, 0.35), (0.6, 1), (1, 1)])
        fillInks = (0...64).map {
            let progress = Double($0) / 64
            return inkColor.withAlphaComponent(CGFloat(isInterlude ? dotOpacity.value(at: progress) : 0.5 + 0.45 * progress)).cgColor
        }
        glowInks = (0...64).map { inkColor.withAlphaComponent(CGFloat($0) / 64 * 0.55).cgColor }
        let all = words.flatMap { $0 }
        let lineStart = timingRange?.lowerBound ?? all.map(\.startMs).min() ?? 0
        let lineEnd = max(lineStart + 1, timingRange?.upperBound ?? all.map(\.endMs).max() ?? lineStart + 1)
        let usesLineTiming = !all.isEmpty && all.allSatisfy {
            $0.startMs == lineStart && $0.endMs <= $0.startMs
        }
        startMs = lineStart
        endMs = lineEnd
        self.fontSize = fontSize
        self.layoutWidth = width
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
                // Spicy's Syllable.ts keeps each split's clock inside a word-group.
                // Only sources without syllable timing share the full line envelope.
                let start = usesLineTiming ? lineStart : part.startMs
                let end = usesLineTiming ? lineEnd : max(start + 1, part.endMs)
                segments.append(Segment(range: range, timing: part, highlightStartMs: start, highlightEndMs: end))
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
            .font: KaraokeFont.shared.font(ofSize: fontSize),
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
                    let path = CTFontCreatePathForGlyph(font, value, nil)
                    bounds = bounds.union(path?.boundingBoxOfPath ?? .null)
                    let glyph = Glyph(font: font, value: value, path: path,
                        position: point, bounds: bounds, advance: max(0, advances[index].width),
                        stringIndex: indices[index], segment: segment, rtl: CTRunGetStatus(run).contains(.rightToLeft))
                    self.segments[segment].glyphs.append(glyphs.count)
                    self.segments[segment].bounds = self.segments[segment].bounds.union(bounds.offsetBy(dx: point.x, dy: point.y))
                    glyphs.append(glyph)
                }
            }
        }
        for glyph in glyphs {
            let box = glyph.bounds.offsetBy(dx: glyph.position.x, dy: glyph.position.y)
            let ui = CGRect(x: box.minX, y: height - box.maxY, width: box.width, height: box.height)
            if !ui.isNull, !ui.isInfinite { inkBounds = inkBounds.union(ui) }
        }
        if inkBounds.isNull { inkBounds = CGRect(x: 0, y: 0, width: width, height: height) }
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
        let fontRevision: Int
        let alignment: HorizontalAlignment
        let rtl: Bool
        let timingRange: ClosedRange<Int>?
    }
    private var key: Key?
    private var stored: KaraokeTextPlan?
    func plan(words: [[KaraokeSyllableDto]], width: CGFloat, fontSize: CGFloat, alignment: HorizontalAlignment, rtl: Bool,
              timingRange: ClosedRange<Int>? = nil) -> KaraokeTextPlan {
        let next = Key(words: words, width: width, fontSize: fontSize, fontRevision: KaraokeFont.shared.revision, alignment: alignment, rtl: rtl, timingRange: timingRange)
        if key == next, let stored { return stored }
        let plan = KaraokeTextPlan(words: words, width: width, fontSize: fontSize, alignment: alignment, rtl: rtl, timingRange: timingRange)
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
    private var renderingMotion = false
    private var motions: [KaraokeWordMotion] = []
    private var onSeek: (() -> Void)?
    private var usesPlaybackClock = false
    private var timingOffsetMs = 0
    private var displayLink: CADisplayLink?
    private let haloLayer = CALayer()
    private var halo = KaraokeSpring(position: 0, frequency: 1, damping: 0.5)
    private var haloStamp: TimeInterval?
    private static let haloCurve = KaraokeAnimationCurve(points: [(0, 0), (1, 1)])

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = false
        haloLayer.shadowOffset = .zero
        layer.addSublayer(haloLayer)
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
        if let plan { updateHalo(in: plan) }
        updateDisplayLink()
    }

    func update(plan: KaraokeTextPlan, currentMs: Int, active: Bool, usesPlaybackClock: Bool = false,
                timingOffsetMs: Int = 0, onSeek: @escaping () -> Void) {
        let changed = self.plan !== plan || self.active != active
        if self.plan !== plan {
            motions = plan.segments.map { _ in KaraokeWordMotion() }
            halo = KaraokeSpring(position: 0, frequency: 1, damping: 0.5)
            haloStamp = nil
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
        if changed || renderingMotion { setNeedsDisplay() }
    }

    private func updateMotion(at position: Int) {
        let seek = abs(position - currentMs) > 500
        currentMs = position
        guard let plan else { return }
        let stamp = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0, stamp - (haloStamp ?? stamp)))
        let start = plan.startMs
        let end = plan.endMs
        let progress = min(1, max(0, Double(position - start) / Double(max(1, end - start))))
        let glow = active ? Self.haloCurve.value(at: progress) : 0
        _ = halo.step(goal: glow, dt: dt, snap: seek || haloStamp == nil || UIAccessibility.isReduceMotionEnabled)
        haloStamp = stamp
        if active || renderingMotion {
            for index in plan.segments.indices {
                let part = plan.segments[index]
                motions[index].update(currentMs: position, startMs: part.timing.startMs, endMs: part.timing.endMs,
                    letterCount: !plan.rtl && part.timing.endMs - part.timing.startMs >= 1000 ? part.glyphs.count : 0, active: active, stamp: stamp)
            }
        }
        renderingMotion = active || motions.contains { !$0.isAtRest } || abs(halo.position) > 0.001 || abs(halo.velocity) > 0.001
        updateHalo(in: plan)
    }

    private var canAnimate: Bool {
        guard usesPlaybackClock, renderingMotion, let window, bounds.width > 0, bounds.height > 0,
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
        guard renderingMotion, glyph.segment < motions.count else { return (.init(translationX: glyph.position.x, y: glyph.position.y), KaraokeMotionSample()) }
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
        let point = CGPoint(x: point.x - plan.horizontalGutter, y: point.y - plan.verticalGutter)
        return plan.glyphs.contains { glyph in
            let box = glyph.bounds.applying(transform(for: glyph, in: plan).0)
            let ui = CGRect(x: box.minX, y: plan.height - box.maxY, width: box.width, height: box.height)
            return ui.insetBy(dx: -1.5, dy: -1.5).contains(point)
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { containsInk(point) }
    override var accessibilityFrame: CGRect {
        get {
            guard let plan else { return super.accessibilityFrame }
            return convert(plan.inkBounds.offsetBy(dx: plan.horizontalGutter, dy: plan.verticalGutter), to: nil)
        }
        set { super.accessibilityFrame = newValue }
    }
    override func accessibilityActivate() -> Bool { onSeek?(); return true }

    private func updateHalo(in plan: KaraokeTextPlan) {
        let amount = min(1, max(0, halo.position))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloLayer.frame = bounds
        haloLayer.shadowColor = plan.inkColor.cgColor
        haloLayer.shadowOpacity = Float(amount * 0.5)
        haloLayer.shadowRadius = 4 + 8 * amount
        if amount > 0.001 {
            let outline = CGMutablePath()
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                tx: plan.horizontalGutter, ty: plan.verticalGutter + plan.height)
            for glyph in plan.glyphs {
                if let path = glyph.path {
                    outline.addPath(path, transform: transform(for: glyph, in: plan).0.concatenating(flip))
                }
            }
            haloLayer.shadowPath = outline
        } else { haloLayer.shadowPath = nil }
        CATransaction.commit()
    }

    override func draw(_ rect: CGRect) {
        guard let plan, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: plan.horizontalGutter, y: plan.verticalGutter + plan.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        if !renderingMotion { CTFrameDraw(plan.frame, context); context.restoreGState(); return }
        for glyph in plan.glyphs {
            let part = plan.segments[glyph.segment]
            let progress = min(1, max(0, Double(currentMs - part.highlightStartMs) / Double(max(1, part.highlightEndMs - part.highlightStartMs))))
            let glow = currentMs < part.highlightStartMs ? 0 : (currentMs <= part.highlightEndMs ? progress : max(0, 1 - Double(currentMs - part.highlightEndMs) / 350))
            let fill = plan.fillInks[min(64, max(0, Int(progress * 64)))]
            let (matrix, _) = transform(for: glyph, in: plan)
            context.saveGState()
            context.concatenate(matrix)
            if glow > 0.01 {
                context.setShadow(offset: .zero, blur: CGFloat(4 + 10 * glow), color: plan.glowInks[min(64, max(0, Int(glow * 64)))])
            }
            if let path = glyph.path {
                context.setFillColor(active ? fill : plan.baseInk)
                context.addPath(path)
                context.fillPath()
            } else {
                var value = glyph.value
                var zero = CGPoint.zero
                context.setFillColor(plan.baseInk)
                context.setAlpha(active ? fill.alpha : 1)
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
