import UIKit
import CoreMotion

/// Sample fast flicks independently of drawing; a short pulse becomes retained momentum.
final class KaraokeSpaceMotion {
    static let shared = KaraokeSpaceMotion()
    private var manager: CMMotionManager?
    private weak var owner: UIView?
    private let lock = NSLock()
    private let sensorQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private struct State {
        var stamp: TimeInterval?
        var previous = SIMD3<Double>.zero
        var filtered = SIMD3<Double>.zero
        var pending = SIMD3<Double>.zero
        var direction = SIMD3<Double>.zero
        var spin = 0.0
        var pulseUntil = 0.0
        var peak = 0.0
    }
    private var state = State()
    private var generation = 0

    func start(for view: UIView) {
        if owner === view { return }
        owner = view
        if manager != nil { return }
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let manager = CMMotionManager()
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 120.0
        self.manager = manager
        lock.lock(); let token = generation; lock.unlock()
        manager.startDeviceMotionUpdates(to: sensorQueue) { [weak self] motion, _ in
            if let motion { self?.ingest(motion, generation: token) }
        }
    }

    func stop(for view: UIView) {
        guard owner == nil || owner === view else { return }
        manager?.stopDeviceMotionUpdates()
        manager = nil
        owner = nil
        lock.lock()
        generation += 1
        state = State()
        lock.unlock()
    }

    private func length(_ value: SIMD3<Double>) -> Double {
        sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
    }

    private func ingest(_ motion: CMDeviceMotion, generation token: Int) {
        let a = motion.userAcceleration
        guard a.x.isFinite, a.y.isFinite, a.z.isFinite, motion.rotationRate.z.isFinite else { return }
        let raw = SIMD3(a.x, a.y, a.z)
        lock.lock()
        defer { lock.unlock() }
        guard token == generation else { return }
        let delta = min(0.05, max(0.001, motion.timestamp - (state.stamp ?? motion.timestamp - 1.0 / 120)))
        let magnitude = length(raw)
        let jerk = state.stamp == nil ? 0 : length(raw - state.previous) / delta
        let blend = 1 - exp(-delta / 0.025)
        state.filtered += (raw - state.filtered) * blend
        state.spin += (motion.rotationRate.z - state.spin) * blend
        // Nonlinear peak gain preserves quick, hard throws that a low-pass filter loses.
        let strength = min(1800, 180 * pow(max(0, magnitude - 0.12), 1.45) * (1 + min(2.8, jerk / 35)))
        if motion.timestamp >= state.pulseUntil, magnitude > 0.22, jerk > 7.5 {
            state.direction = raw / max(0.001, magnitude)
            state.peak = 0
            // Ignore the braking half of one flick rather than canceling its throw.
            state.pulseUntil = motion.timestamp + 0.28
        }
        let projection = raw.x * state.direction.x + raw.y * state.direction.y + raw.z * state.direction.z
        if motion.timestamp < state.pulseUntil, projection > magnitude * 0.5, strength > state.peak {
            state.pending += state.direction * (strength - state.peak)
            state.peak = strength
            let pending = length(state.pending)
            if pending > 1800 { state.pending *= 1800 / pending }
        }
        state.previous = raw
        state.stamp = motion.timestamp
    }

    func sample(for view: UIView, delta: CGFloat) -> (acceleration: CGVector, spin: CGFloat, depth: CGFloat, impulse: CGVector, depthImpulse: CGFloat) {
        guard owner === view else { return (.zero, 0, 0, .zero, 0) }
        lock.lock()
        let sample = state
        state.pending = .zero
        lock.unlock()
        func screen(_ value: SIMD3<Double>) -> CGVector {
            let x = CGFloat(value.x), y = CGFloat(value.y)
            switch view.window?.windowScene?.interfaceOrientation ?? .portrait {
            case .landscapeLeft: return CGVector(dx: y, dy: x)
            case .landscapeRight: return CGVector(dx: -y, dy: -x)
            case .portraitUpsideDown: return CGVector(dx: -x, dy: y)
            default: return CGVector(dx: x, dy: -y)
            }
        }
        let gentle = (sample.stamp ?? 0) < sample.pulseUntil ? 0.06 : 1.0
        let filtered = sample.filtered * gentle
        var acceleration = screen(filtered)
        if abs(acceleration.dx) < 0.015 { acceleration.dx = 0 }
        if abs(acceleration.dy) < 0.015 { acceleration.dy = 0 }
        return (acceleration, CGFloat(min(12, max(-12, sample.spin))), CGFloat(filtered.z),
                screen(sample.pending), CGFloat(sample.pending.z))
    }
}
