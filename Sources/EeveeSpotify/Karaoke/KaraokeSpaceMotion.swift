import UIKit
import CoreMotion
import Combine

/// Sample fast flicks independently of drawing; a short pulse becomes retained momentum.
final class KaraokeSpaceMotion: ObservableObject {
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
    @Published private(set) var recording = false
    @Published private(set) var sampleURL: URL?
    @Published private(set) var recordingStatus = ""
    private struct RecordedSample: Encodable {
        let time: Double
        let userAcceleration: [Double]
        let gravity: [Double]
        let rotationRate: [Double]
        let quaternion: [Double]
    }
    private struct Recording: Encodable {
        let schemaVersion = 1
        let recordedAt: String
        let interfaceOrientation: Int
        let screenSize: [Double]
        let units = ["acceleration": "g", "rotationRate": "rad/s", "time": "seconds"]
        let samples: [RecordedSample]
    }
    private var capture: [RecordedSample]?
    private var captureStamp: Double?
    private var captureDate = ""
    private var captureOrientation = 0
    private var captureSize = [Double]()
    private var captureToken = 0
    private var captureTimer: DispatchWorkItem?
    private var captureObserver: NSObjectProtocol?

    func start(for view: UIView) {
        if owner !== view {
            owner = view
            lock.lock(); state.pending = .zero; lock.unlock()
        }
        _ = ensureSensor()
    }

    private func ensureSensor() -> Bool {
        if manager != nil { return true }
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let manager = CMMotionManager()
        guard manager.isDeviceMotionAvailable else { return false }
        manager.deviceMotionUpdateInterval = 1.0 / 120.0
        self.manager = manager
        lock.lock(); let token = generation; lock.unlock()
        manager.startDeviceMotionUpdates(to: sensorQueue) { [weak self] motion, _ in
            if let motion { self?.ingest(motion, generation: token) }
        }
        return true
    }

    func stop(for view: UIView) {
        guard owner == nil || owner === view else { return }
        owner = nil
        stopSensorIfUnused()
    }

    private func stopSensorIfUnused() {
        guard owner == nil, !recording else { return }
        manager?.stopDeviceMotionUpdates()
        manager = nil
        lock.lock()
        generation += 1
        state = State()
        lock.unlock()
    }

    func recordSample() {
        guard !recording else { return }
        guard ensureSensor() else { recordingStatus = "karaoke_motion_unavailable".localized; return }
        if let sampleURL { try? FileManager.default.removeItem(at: sampleURL) }
        sampleURL = nil
        captureToken += 1
        recording = true
        recordingStatus = ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        captureDate = formatter.string(from: Date())
        captureSize = [Double(UIScreen.main.bounds.width), Double(UIScreen.main.bounds.height)]
        captureOrientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.interfaceOrientation.rawValue ?? 0
        lock.lock(); capture = []; captureStamp = nil; lock.unlock()
        let timer = DispatchWorkItem { [weak self] in self?.finishRecording() }
        captureTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timer)
        captureObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in self?.finishRecording() }
    }

    private func finishRecording() {
        guard recording else { return }
        captureTimer?.cancel(); captureTimer = nil
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
        captureObserver = nil
        lock.lock()
        let samples = capture ?? []
        capture = nil; captureStamp = nil
        lock.unlock()
        recording = false
        stopSensorIfUnused()
        guard !samples.isEmpty else { recordingStatus = "karaoke_motion_failed".localized; return }
        let token = captureToken
        let recording = Recording(recordedAt: captureDate, interfaceOrientation: captureOrientation,
            screenSize: captureSize, samples: samples)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("EeveeMotion-" + UUID().uuidString + ".json")
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(recording).write(to: file, options: .atomic)
                DispatchQueue.main.async {
                    guard let self, self.captureToken == token else { try? FileManager.default.removeItem(at: file); return }
                    self.sampleURL = file
                    self.recordingStatus = "karaoke_motion_ready".localized
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.captureToken == token else { return }
                    self.recordingStatus = "karaoke_motion_failed".localized
                }
            }
        }
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
        if capture != nil {
            let origin = captureStamp ?? motion.timestamp
            captureStamp = origin
            if motion.timestamp - origin <= 5.05, (capture?.count ?? 0) < 800 {
                let g = motion.gravity, r = motion.rotationRate, q = motion.attitude.quaternion
                capture?.append(RecordedSample(time: motion.timestamp - origin,
                    userAcceleration: [a.x, a.y, a.z], gravity: [g.x, g.y, g.z],
                    rotationRate: [r.x, r.y, r.z], quaternion: [q.x, q.y, q.z, q.w]))
            }
        }
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
