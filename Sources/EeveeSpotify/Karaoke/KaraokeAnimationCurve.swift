import Foundation

// Native adaptation of Spicy Lyrics LyricsAnimator.ts, reference 89444e8.
// See bundled SpicyLyrics-LICENSE.txt and SpicyLyrics-NOTICE.txt.
struct KaraokeAnimationCurve {
    let points: [(time: Double, value: Double)]
    private let secondDerivatives: [Double]

    init(points: [(time: Double, value: Double)]) {
        self.points = points
        let count = points.count
        var second = Array(repeating: 0.0, count: count)
        var work = second
        if count > 2 {
            for index in 1..<(count - 1) {
                let left = points[index].time - points[index - 1].time
                let right = points[index + 1].time - points[index].time
                let fraction = left / (left + right)
                let pivot = fraction * second[index - 1] + 2
                second[index] = (fraction - 1) / pivot
                let slopes = (points[index + 1].value - points[index].value) / right
                    - (points[index].value - points[index - 1].value) / left
                work[index] = (6 * slopes / (left + right) - fraction * work[index - 1]) / pivot
            }
            for index in stride(from: count - 2, through: 0, by: -1) {
                second[index] = second[index] * second[index + 1] + work[index]
            }
        }
        secondDerivatives = second
    }

    func value(at progress: Double) -> Double {
        let p = min(1, max(0, progress))
        guard points.count > 1 else { return points.first?.value ?? 0 }
        let index = (0..<(points.count - 1)).first { p <= points[$0 + 1].time } ?? points.count - 2
        let span = points[index + 1].time - points[index].time
        let a = (points[index + 1].time - p) / span
        let b = (p - points[index].time) / span
        return a * points[index].value + b * points[index + 1].value
            + ((a * a * a - a) * secondDerivatives[index]
                + (b * b * b - b) * secondDerivatives[index + 1]) * span * span / 6
    }

    static let wordScale = KaraokeAnimationCurve(points: [(0, 0.95), (0.7, 1.0505), (1, 1)])
    static let letterScale = KaraokeAnimationCurve(points: [(0, 0.95), (0.7, 1.175), (1, 1)])
    static let glow = KaraokeAnimationCurve(points: [(0, 0), (0.15, 1), (0.6, 1), (1, 0)])
    static let yOffset = KaraokeAnimationCurve(points: [(0, 0.01), (0.9, -1.0 / 60), (1, 0)])
    static let letterYOffset = KaraokeAnimationCurve(points: [(0, 0.01), (0.9, -1.0 / 56), (1, 0)])
}

/// Analytical damped oscillator used by the plugin's Spring.ts (Fraktality/spr, MIT).
struct KaraokeSpring {
    var position: Double
    var velocity = 0.0
    let frequency: Double
    let damping: Double

    mutating func step(goal: Double, dt: Double, snap: Bool) -> Double {
        if snap { position = goal; velocity = 0; return position }
        let f = frequency * 2 * Double.pi
        let offset = position - goal
        let c = sqrt(max(0.000001, 1 - damping * damping))
        let decay = exp(-damping * f * dt)
        let cosine = cos(dt * f * c)
        let sine = sin(dt * f * c)
        let z = sine / c
        position = (offset * (cosine + z * damping) + velocity * sine / (f * c)) * decay + goal
        velocity = (velocity * (cosine - z * damping) - offset * z * f) * decay
        return position
    }
}

struct KaraokeMotionSample {
    var scale = 0.95
    var offset = 0.01
    var glow = 0.0
}

struct KaraokeMotionSprings {
    var scale = KaraokeSpring(position: 0.95, frequency: 0.88, damping: 0.64)
    var offset = KaraokeSpring(position: 0.01, frequency: 1.45, damping: 0.4)
    var glow = KaraokeSpring(position: 0, frequency: 1.18, damping: 0.56)

    mutating func step(target: KaraokeMotionSample, dt: Double, snap: Bool) -> KaraokeMotionSample {
        KaraokeMotionSample(
            scale: scale.step(goal: target.scale, dt: dt, snap: snap),
            offset: offset.step(goal: target.offset, dt: dt, snap: snap),
            glow: glow.step(goal: target.glow, dt: dt, snap: snap)
        )
    }
}

struct KaraokeWordMotion {
    var word = KaraokeMotionSample()
    var letters: [KaraokeMotionSample] = []
    private var wordSprings = KaraokeMotionSprings()
    private var letterSprings: [KaraokeMotionSprings] = []
    private var previousMs: Int?
    private var previousStamp: TimeInterval?

    mutating func update(currentMs: Int, startMs: Int, endMs: Int, letterCount: Int, active: Bool, stamp: TimeInterval) {
        let dt = min(0.05, max(0, stamp - (previousStamp ?? stamp)))
        let snap = previousMs == nil || abs(currentMs - (previousMs ?? currentMs)) > 500
            || currentMs < startMs || !active
        previousMs = currentMs
        previousStamp = stamp
        let progress = min(1, max(0, Double(currentMs - startMs) / Double(max(1, endMs - startMs))))
        let target = KaraokeMotionSample(
            scale: KaraokeAnimationCurve.wordScale.value(at: progress),
            offset: KaraokeAnimationCurve.yOffset.value(at: progress),
            glow: KaraokeAnimationCurve.glow.value(at: progress)
        )
        word = wordSprings.step(target: target, dt: dt, snap: snap)
        guard letterCount > 0 else { letters = []; return }
        if letterSprings.count != letterCount {
            letterSprings = Array(repeating: KaraokeMotionSprings(), count: letterCount)
        }
        let position = progress * Double(letterCount)
        let activeIndex = min(letterCount - 1, Int(position))
        let localProgress = progress >= 1 ? 1 : position - Double(activeIndex)
        letters = (0..<letterCount).map { index in
            let distance = Double(abs(index - activeIndex))
            let falloff = 1 / (1 + pow(distance, 2.8))
            let glowFalloff = 1 / (1 + distance * 0.9)
            let sung = progress >= 1
            let future = index > activeIndex || currentMs < startMs
            let baseScale = KaraokeAnimationCurve.letterScale.value(at: localProgress)
            let baseOffset = KaraokeAnimationCurve.letterYOffset.value(at: localProgress)
            let baseGlow = KaraokeAnimationCurve.glow.value(at: localProgress)
            let target = KaraokeMotionSample(
                scale: sung ? 1 : (future ? 0.95 : 0.95 + (baseScale - 0.95) * falloff),
                offset: sung ? 0 : (future ? 0.01 : 0.01 + (baseOffset - 0.01) * falloff),
                glow: sung || future ? 0 : baseGlow * glowFalloff
            )
            return letterSprings[index].step(target: target, dt: dt, snap: snap)
        }
    }
}
