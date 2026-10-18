import SwiftUI
import UIKit
import NaturalLanguage

/// Native adaptation of the fork's SpaceGravity.ts (89444e8).
/// See the bundled SpicyLyrics license and notice for attribution.
@available(iOS 15.0, *)
struct KaraokeSpaceGravityView: View {
    let lyrics: KaraokeLyricsDto
    let layouts: [KaraokeLineLayout]
    let options: KaraokeOptions
    let size: CGSize
    @State private var creditsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            KaraokeGravityStage(layouts: layouts, options: options)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            ScrollView(showsIndicators: false) {
                KaraokeCreditsFooterView(lyrics: lyrics)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: KaraokeGravityCreditsHeight.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(creditsHeight, max(0, size.height * 0.28)))
        }
        .onPreferenceChange(KaraokeGravityCreditsHeight.self) { height in
            if height.isFinite, abs(height - creditsHeight) > 0.5 { creditsHeight = height }
        }
    }
}

private struct KaraokeGravityCreditsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@available(iOS 15.0, *)
private struct KaraokeGravityStage: UIViewRepresentable {
    let layouts: [KaraokeLineLayout]
    let options: KaraokeOptions
    func makeUIView(context: Context) -> KaraokeGravityField { KaraokeGravityField() }
    func updateUIView(_ view: KaraokeGravityField, context: Context) { view.configure(layouts: layouts, options: options) }
    static func dismantleUIView(_ view: KaraokeGravityField, coordinator: ()) { view.stop() }
}

@available(iOS 15.0, *)
private final class KaraokeGravityField: UIView, UIGestureRecognizerDelegate {
    private struct Word {
        let id: Int
        let line: Int
        let parent: Int
        let ordinal: Int?
        let syllables: [KaraokeSyllableDto]
        let startMs: Int
        let endMs: Int
        let dot: Bool
    }
    private enum Role: Equatable { case current, next, previous }
    private final class Body {
        let word: Word
        let canvas: KaraokeTextCanvas
        let plan: KaraokeTextPlan
        let seed: UInt32
        let speedMultiplier: CGFloat
        var position: CGPoint
        var velocity: CGVector
        var angle: CGFloat = 0
        var spin: CGFloat
        var scale: CGFloat = 1
        var radius: CGFloat
        var bounces = 0
        var flingUntil: TimeInterval = 0
        var role: Role?
        var roleOpacity: CGFloat = 0
        let born: TimeInterval
        var exiting: TimeInterval?

        init(word: Word, canvas: KaraokeTextCanvas, plan: KaraokeTextPlan, seed: UInt32,
             multiplier: CGFloat, position: CGPoint, born: TimeInterval) {
            self.word = word; self.canvas = canvas; self.plan = plan; self.seed = seed
            speedMultiplier = multiplier; self.position = position; self.born = born
            let direction = gravityRandom(seed &+ 4) * .pi * 2
            let speed = (4.4 + gravityRandom(seed &+ 3) * 5.6) * multiplier
            velocity = CGVector(dx: cos(direction) * speed, dy: sin(direction) * speed)
            spin = (gravityRandom(seed &+ 2) * 2 - 1) * 19 * .pi / 180
            radius = max(14, hypot(canvas.bounds.width, canvas.bounds.height) * 0.5 + canvas.bounds.height * 0.3)
        }
    }

    private var layouts = [KaraokeLineLayout]()
    private var options = KaraokeOptions()
    private var signature = ""
    private var words = [Word]()
    private var leadLines = [Int]()
    private var bodies = [Int: Body]()
    private var linePositions = [Int: [Int: CGPoint]]()
    private var selection = ""
    private var lastSize = CGSize.zero
    private var lastStamp: TimeInterval?
    private var lastReducedMotion: Bool?
    private var staticLayoutDirty = true
    private var displayLink: CADisplayLink?
    private var observers = [NSObjectProtocol]()
    private var fontSize: CGFloat {
        1.3 * CGFloat(KaraokeOptions.textScaleBaseline * options.textScale) * min(36, max(28, bounds.width * 0.075))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(revealControls))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        observers = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.start() }
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        displayLink?.invalidate()
        KaraokeSpaceMotion.shared.stop(for: self)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    @objc private func revealControls() { KaraokeOverlayPresenter.interact() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is KaraokeTextCanvas)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { start() }
    }
    private func start() {
        guard displayLink == nil, window != nil, UIApplication.shared.applicationState == .active else { return }
        let relay = KaraokeGravityTick(owner: self)
        let link = CADisplayLink(target: relay, selector: #selector(KaraokeGravityTick.tick(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastStamp = nil
    }
    func stop() {
        displayLink?.invalidate(); displayLink = nil
        lastStamp = nil
        KaraokeSpaceMotion.shared.stop(for: self)
    }

    func configure(layouts: [KaraokeLineLayout], options: KaraokeOptions) {
        let key = "\(options.textScale):\(options.textAlignment.rawValue)|" + layouts.map { line in
            "\(line.startMs):\(line.endMs):\(line.isRTL):\(line.isInterlude):\(line.isBackground):\(line.isOppositeAligned)|" +
                line.words.map { $0.map { "\($0.text):\($0.startMs):\($0.endMs)" }.joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
        }.joined(separator: "\n")
        self.options = options
        guard signature != key else { return }
        signature = key
        self.layouts = layouts
        for body in bodies.values { body.canvas.removeFromSuperview() }
        bodies.removeAll()
        accessibilityElements = nil
        linePositions.removeAll()
        words.removeAll()
        leadLines.removeAll()
        selection = ""
        var ordinal = 0, parent = 0
        for (index, line) in layouts.enumerated() {
            if !line.isBackground && !line.isInterlude { parent = index; leadLines.append(index) }
            let entities: [[KaraokeSyllableDto]]
            if line.isInterlude {
                entities = (0..<3).map { dot in
                    let duration = max(1, line.endMs - line.startMs)
                    return [KaraokeSyllableDto(text: "●", startMs: line.startMs + duration * dot / 3,
                                              endMs: line.startMs + duration * (dot + 1) / 3, isPartOfWord: false)]
                }
            } else {
                entities = line.words.flatMap { gravityWords($0) }
            }
            for syllables in entities where !syllables.isEmpty {
                let lead = !line.isBackground && !line.isInterlude
                let start = syllables.first?.startMs ?? line.startMs
                let end = max(start + 1, syllables.last?.endMs ?? line.endMs)
                words.append(Word(id: words.count, line: index, parent: parent, ordinal: lead ? ordinal : nil,
                                  syllables: syllables, startMs: start, endMs: end, dot: line.isInterlude))
                if lead { ordinal += 1 }
            }
        }
        staticLayoutDirty = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1, bounds.size != lastSize else { return }
        if lastSize.width > 1 && abs(lastSize.width - bounds.width) < 0.5 {
            for body in bodies.values {
                body.position.x *= bounds.width / lastSize.width
                body.position.y *= bounds.height / max(1, lastSize.height)
                constrain(body)
            }
        } else {
            for body in bodies.values { body.canvas.removeFromSuperview() }
            bodies.removeAll()
        }
        lastSize = bounds.size
        linePositions.removeAll()
        selection = ""
        staticLayoutDirty = true
    }

    fileprivate func advance(_ stamp: TimeInterval) {
        guard let window, bounds.width > 1, bounds.height > 1, !words.isEmpty,
              convert(bounds, to: window).intersects(window.bounds),
              UIApplication.shared.applicationState == .active else {
            KaraokeSpaceMotion.shared.stop(for: self); lastStamp = nil
            return
        }
        var ancestor: UIView? = self
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.01 {
                KaraokeSpaceMotion.shared.stop(for: self); lastStamp = nil
                return
            }
            ancestor = current.superview
        }
        let delta = CGFloat(min(0.1, max(0, stamp - (lastStamp ?? stamp))))
        lastStamp = stamp
        let currentMs = KaraokePlaybackTracker.shared.currentPositionMs() + Int(options.timingOffsetMs)
        let reduced = UIAccessibility.isReduceMotionEnabled || UIAccessibility.isVoiceOverRunning
        if lastReducedMotion != reduced {
            selection = ""; staticLayoutDirty = true; lastReducedMotion = reduced
            accessibilityElements = nil
        }
        select(at: currentMs, now: stamp, reduced: reduced)
        let active = bodies.values.filter { $0.exiting == nil }
        if reduced {
            KaraokeSpaceMotion.shared.stop(for: self)
            if staticLayoutDirty { arrangeStatic(active); staticLayoutDirty = false }
        } else {
            KaraokeSpaceMotion.shared.start(for: self)
            let sample = KaraokeSpaceMotion.shared.sample(for: self, delta: delta)
            for body in active {
                let radial = CGVector(dx: body.position.x - bounds.midX, dy: body.position.y - bounds.midY)
                let distance = max(48, hypot(radial.dx, radial.dy))
                body.velocity.dx += sample.impulse.dx + radial.dx / distance * sample.depthImpulse
                body.velocity.dy += sample.impulse.dy + radial.dy / distance * sample.depthImpulse
                if hypot(sample.impulse.dx, sample.impulse.dy) + abs(sample.depthImpulse) > 20 {
                    body.flingUntil = stamp + 3
                }
            }
            var remaining = delta
            while remaining > 0 {
                let step = min(0.05, remaining)
                remaining -= step
                separate(active, delta: step)
                for body in active {
                    body.velocity.dx += sample.acceleration.dx * 900 * 1.1 * step
                    body.velocity.dy += sample.acceleration.dy * 900 * 1.1 * step
                    let radial = CGVector(dx: body.position.x - bounds.midX, dy: body.position.y - bounds.midY)
                    let distance = max(48, hypot(radial.dx, radial.dy))
                    body.velocity.dx += radial.dx / distance * sample.depth * 600 * step
                    body.velocity.dy += radial.dy / distance * sample.depth * 600 * step
                    body.spin += sample.spin * 1.4 * step
                    let speed = hypot(body.velocity.dx, body.velocity.dy)
                    let maximum: CGFloat = 16 * body.speedMultiplier
                    if speed > maximum {
                        let drag: CGFloat = body.flingUntil > stamp ? 0.16 : 0.6
                        let next = min(1800, maximum + (speed - maximum) * exp(-drag * step))
                        body.velocity.dx *= next / speed; body.velocity.dy *= next / speed
                    }
                    body.velocity.dy -= 0.4 * max(0, (body.position.y / bounds.height - 0.45) / 0.55) * step
                    body.position.x += body.velocity.dx * step
                    body.position.y += body.velocity.dy * step
                    body.spin = min(4, max(-4, body.spin * exp(-0.18 * step)))
                    body.angle = (body.angle + body.spin * step).truncatingRemainder(dividingBy: .pi * 2)
                    constrain(body)
                }
            }
        }
        var expired = [Int]()
        for body in bodies.values {
            let role = role(for: body.word, at: currentMs)
            if body.role != role {
                body.role = role
                if role == .current { bringSubviewToFront(body.canvas) }
            }
            let target: CGFloat = role == .current ? 1 : (role == .next ? 0.34 : 0.22)
            body.roleOpacity += (target - body.roleOpacity) * min(1, delta / 0.18)
            let presence: CGFloat
            if let exiting = body.exiting {
                presence = max(0, 1 - CGFloat((stamp - exiting) / 0.18))
                if presence == 0 { expired.append(body.word.id) }
            } else {
                presence = reduced ? 1 : min(1, CGFloat((stamp - body.born) / 0.18))
            }
            body.canvas.alpha = body.roleOpacity * presence
            body.canvas.center = body.position
            body.canvas.transform = CGAffineTransform(rotationAngle: reduced ? 0 : body.angle).scaledBy(x: body.scale, y: body.scale)
            body.canvas.update(plan: body.plan, currentMs: currentMs, active: role == .current, onSeek: { [weak self, start = body.word.startMs] in
                self?.seek(start)
            })
        }
        for id in expired { bodies.removeValue(forKey: id)?.canvas.removeFromSuperview() }
    }

    private func role(for word: Word, at position: Int) -> Role {
        if word.dot { return .current }
        let line = layouts[word.line]
        let start = line.isBackground ? word.startMs : line.startMs
        let end = line.isBackground ? word.endMs : line.endMs
        return position < start ? .next : (position < end ? .current : .previous)
    }

    private func select(at position: Int, now: TimeInterval, reduced: Bool) {
        let leadWords = words.filter { $0.ordinal != nil }
        let line = leadLines.last(where: { layouts[$0].startMs <= position && position < layouts[$0].endMs })
            ?? leadLines.first(where: { layouts[$0].startMs > position }) ?? leadLines.last
        let anchorWords = leadWords.filter { $0.line == line }
        let anchor = anchorWords.first(where: { position >= $0.startMs && position < $0.endMs })
            ?? anchorWords.first(where: { $0.startMs > position }) ?? anchorWords.last
        let count = min(leadWords.count, min(120, max(12, Int(ceil(bounds.width * bounds.height / 33_334)))))
        let first = max(0, min((anchor?.ordinal ?? 0) - (max(1, count) - 1) / 2, leadWords.count - count))
        let dots = words.filter { $0.dot && position >= layouts[$0.line].startMs && position < layouts[$0.line].endMs }
        let key = "\(line ?? -1):\(anchor?.id ?? -1):\(count):\(dots.first?.id ?? -1):\(reduced)"
        guard key != selection else { return }
        selection = key
        var leads = leadWords.filter { word in
            word.line == line || (!reduced && word.ordinal.map { $0 >= first && $0 < first + count } == true)
        }
        // Bound native views and pairwise physics even for malformed song-long lyric lines.
        if leads.count > 120 {
            let center = anchor?.ordinal ?? 0
            leads = Array(leads.sorted { abs(($0.ordinal ?? 0) - center) < abs(($1.ordinal ?? 0) - center) }.prefix(120))
                .sorted { $0.id < $1.id }
        }
        let parents = Set(leads.map { $0.line })
        let backing = words.filter { layouts[$0.line].isBackground && parents.contains($0.parent) }
            .sorted { abs($0.startMs - position) < abs($1.startMs - position) }
        let selected = leads + Array(backing.prefix(max(0, 160 - leads.count - dots.count))) + dots
        let wanted = Set(selected.map { $0.id })
        for body in bodies.values {
            if wanted.contains(body.word.id) { body.exiting = nil; body.canvas.isUserInteractionEnabled = !body.word.dot }
            else if body.exiting == nil { body.exiting = now; body.canvas.isUserInteractionEnabled = false }
        }
        for word in selected where bodies[word.id] == nil { spawn(word, now: now) }
        staticLayoutDirty = true
    }

    private func spawn(_ word: Word, now: TimeInterval) {
        let line = layouts[word.line]
        let text = word.syllables.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        let font = fontSize * (word.dot ? 0.5 : (line.isBackground ? 0.72 : 1))
        let width = min(max(1, bounds.width - 36), ceil((text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: font, weight: .bold)]).width) + font * 0.3 + 4)
        let color: UIColor = line.isOppositeAligned ? UIColor(red: 1, green: 140.0 / 255, blue: 168.0 / 255, alpha: 1) : .white
        let plan = KaraokeTextPlan(words: [word.syllables], width: width, fontSize: font,
                                   alignment: .leading, rtl: line.isRTL, inkColor: color)
        let canvas = KaraokeTextCanvas(frame: CGRect(x: 0, y: 0, width: width, height: plan.height))
        canvas.alpha = 0
        canvas.isUserInteractionEnabled = !word.dot
        if word.dot { canvas.isAccessibilityElement = false }
        addSubview(canvas)
        let starts = Array(Set(words.filter { $0.line == word.line }.map { $0.startMs })).sorted()
        let wpm = starts.count > 1 ? CGFloat(starts.count - 1) * 60_000 / CGFloat(max(1, starts.last! - starts[0])) : 0
        let multiplier = 1 + min(1, max(0, (wpm - 60) / 120)) * 0.75
        let seed = gravityHash("\(line.startMs):\(line.endMs):\(text):\(word.id)")
        let natural = naturalPosition(for: word)
        let position = CGPoint(x: natural.x + (gravityRandom(seed &+ 5) * 2 - 1) * width * 1.35,
                               y: natural.y + (gravityRandom(seed &+ 6) * 2 - 1) * plan.height * 1.35)
        let body = Body(word: word, canvas: canvas, plan: plan, seed: seed, multiplier: multiplier, position: position, born: now)
        bodies[word.id] = body
        constrain(body)
    }

    private func naturalPosition(for word: Word) -> CGPoint {
        if let cached = linePositions[word.line]?[word.id] { return cached }
        let line = layouts[word.line]
        let font = fontSize * (word.dot ? 0.5 : (line.isBackground ? 0.72 : 1))
        let nativeFont = UIFont.systemFont(ofSize: font, weight: .bold)
        var rows = [[(id: Int, size: CGSize)]]()
        var row = [(id: Int, size: CGSize)]()
        var rowWidth: CGFloat = 0
        for item in words where item.line == word.line {
            let text = item.syllables.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
            let measured = (text as NSString).size(withAttributes: [.font: nativeFont])
            let size = CGSize(width: min(max(1, bounds.width - 36), ceil(measured.width) + font * 0.3 + 4),
                              height: ceil(nativeFont.lineHeight) + 2)
            if !row.isEmpty, rowWidth + size.width > bounds.width - 36 {
                rows.append(row); row.removeAll(); rowWidth = 0
            }
            row.append((item.id, size)); rowWidth += size.width + 6
        }
        if !row.isEmpty { rows.append(row) }
        let height = rows.reduce(CGFloat.zero) { $0 + ($1.map { $0.size.height }.max() ?? 0) + 12 } - 12
        var y = max(18, (bounds.height - height) / 2)
        var positions = [Int: CGPoint]()
        for row in rows {
            let width = row.reduce(CGFloat.zero) { $0 + $1.size.width } + CGFloat(max(0, row.count - 1)) * 6
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            let rightAligned: Bool
            switch options.textAlignment {
            case .automatic: rightAligned = line.isRTL != line.isOppositeAligned
            case .trailing: rightAligned = !line.isRTL
            case .leading, .center: rightAligned = line.isRTL
            }
            let center = word.dot || options.textAlignment == .center
            var x: CGFloat = center ? (bounds.width - width) / 2 : (rightAligned ? bounds.width - 18 - width : 18)
            for item in (line.isRTL ? Array(row.reversed()) : row) {
                positions[item.id] = CGPoint(x: x + item.size.width / 2, y: y + rowHeight / 2)
                x += item.size.width + 6
            }
            y += rowHeight + 12
        }
        linePositions[word.line] = positions
        return positions[word.id] ?? CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func seek(_ milliseconds: Int) {
        guard KaraokePlaybackTracker.shared.seek(toMs: max(0, milliseconds - Int(options.timingOffsetMs))) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func separate(_ active: [Body], delta: CGFloat) {
        for index in active.indices {
            for otherIndex in 0..<index {
                let body = active[index], other = active[otherIndex]
                let dx = body.position.x - other.position.x
                let dy = body.position.y - other.position.y
                let distance = max(0.001, hypot(dx, dy))
                let influence = body.radius * body.scale + other.radius * other.scale + 10
                guard distance < influence else { continue }
                let nudge = (influence - distance) / influence * 5 * delta
                body.velocity.dx += dx / distance * nudge; body.velocity.dy += dy / distance * nudge
                other.velocity.dx -= dx / distance * nudge; other.velocity.dy -= dy / distance * nudge
            }
        }
    }

    private func constrain(_ body: Body) {
        let maximumRadius = max(1, min(bounds.width, bounds.height) * 0.5 - 18)
        body.scale = min(1, maximumRadius / max(1, body.radius))
        let radius = body.radius * body.scale
        guard body.position.x.isFinite, body.position.y.isFinite, body.velocity.dx.isFinite,
              body.velocity.dy.isFinite, body.angle.isFinite, body.spin.isFinite else {
            body.position = CGPoint(x: bounds.midX, y: bounds.midY)
            body.velocity = .zero; body.angle = 0; body.spin = 0
            return
        }
        let left = 18 + radius, right = max(left, bounds.width - 18 - radius)
        let top = 18 + radius, bottom = max(top, bounds.height - 18 - radius)
        if right - left < 1 { body.position.x = (left + right) / 2; body.velocity.dx = 0 }
        else if body.position.x < left { body.position.x = left; bounce(body, horizontal: true, direction: 1) }
        else if body.position.x > right { body.position.x = right; bounce(body, horizontal: true, direction: -1) }
        if bottom - top < 1 { body.position.y = (top + bottom) / 2; body.velocity.dy = 0 }
        else if body.position.y < top { body.position.y = top; bounce(body, horizontal: false, direction: 1) }
        else if body.position.y > bottom { body.position.y = bottom; bounce(body, horizontal: false, direction: -1) }
    }

    private func bounce(_ body: Body, horizontal: Bool, direction: CGFloat) {
        let velocity = horizontal ? body.velocity.dx : body.velocity.dy
        guard velocity * direction < 0 else { return }
        let strength = 0.82 + pow(gravityRandom(body.seed &+ UInt32(truncatingIfNeeded: body.bounces)), 2) * (2.4 - 0.82)
        body.bounces &+= 1
        let flick = body.flingUntil > (lastStamp ?? 0)
        let rebound = direction * (flick ? min(1800, abs(velocity) * 0.985)
            : min(16 * 2.4 * body.speedMultiplier, abs(velocity) * strength))
        if horizontal { body.velocity.dx = rebound } else { body.velocity.dy = rebound }
    }

    private func arrangeStatic(_ active: [Body]) {
        let ordered = active.sorted { $0.word.id < $1.word.id }
        accessibilityElements = ordered.filter { !$0.word.dot }.map { $0.canvas }
        var x: CGFloat = 18, y: CGFloat = 18, rowHeight: CGFloat = 0
        for body in ordered {
            let width = body.canvas.bounds.width * body.scale, height = body.canvas.bounds.height * body.scale
            if x + width > bounds.width - 18 && x > 18 { x = 18; y += rowHeight + 12; rowHeight = 0 }
            body.position = CGPoint(x: x + width / 2, y: y + height / 2)
            body.angle = 0
            body.canvas.isAccessibilityElement = !body.word.dot
            x += width + 6; rowHeight = max(rowHeight, height)
        }
    }
}

@available(iOS 15.0, *)
private final class KaraokeGravityTick: NSObject {
    weak var owner: KaraokeGravityField?
    init(owner: KaraokeGravityField) { self.owner = owner; super.init() }
    @objc func tick(_ link: CADisplayLink) { owner?.advance(link.timestamp) }
}

private func gravityHash(_ value: String) -> UInt32 {
    var result: UInt32 = 2_166_136_261
    for character in value.utf16 { result = (result ^ UInt32(character)) &* 16_777_619 }
    return result
}

private func gravityRandom(_ seed: UInt32) -> CGFloat {
    var value = seed &+ 0x6D2B79F5
    value = (value ^ (value >> 15)) &* (value | 1)
    value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
    return CGFloat(value ^ (value >> 14)) / 4_294_967_296
}

/// Preserve authored words; segment unsplit line/CJK text using native word boundaries.
/// Retain punctuation and map each split back to its original syllable timing.
private func gravityWords(_ word: [KaraokeSyllableDto]) -> [[KaraokeSyllableDto]] {
    let text = word.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
    guard !text.isEmpty else { return [] }
    let cjk = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    guard cjk || text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return [word] }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
    guard ranges.count > 1 else { return [word] }
    var source = [(range: NSRange, syllable: KaraokeSyllableDto)]()
    var offset = 0
    for syllable in word {
        let length = syllable.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        source.append((NSRange(location: offset, length: length), syllable))
        offset += length
    }
    var result = [[KaraokeSyllableDto]]()
    for index in ranges.indices {
        let lower = index == 0 ? text.startIndex : ranges[index].lowerBound
        let upper = index + 1 < ranges.count ? ranges[index + 1].lowerBound : text.endIndex
        let range = NSRange(lower..<upper, in: text)
        var parts = [KaraokeSyllableDto]()
        for item in source {
            let overlap = NSIntersectionRange(range, item.range)
            guard overlap.length > 0, let slice = Range(overlap, in: text) else { continue }
            let fragment = String(text[slice]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { continue }
            let duration = max(1, item.syllable.endMs - item.syllable.startMs)
            let start = item.syllable.startMs + duration * (overlap.location - item.range.location) / max(1, item.range.length)
            let end = item.syllable.startMs + duration * (NSMaxRange(overlap) - item.range.location) / max(1, item.range.length)
            parts.append(KaraokeSyllableDto(text: fragment, startMs: start, endMs: max(start + 1, end), isPartOfWord: true))
        }
        if !parts.isEmpty { parts[parts.count - 1].isPartOfWord = false; result.append(parts) }
    }
    return result.isEmpty ? [word] : result
}
