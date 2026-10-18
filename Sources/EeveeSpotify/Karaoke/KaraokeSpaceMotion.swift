import UIKit
import CoreMotion

/// Phone acceleration replaces SpaceGravity.ts's desktop window-motion impulse.
/// Keep a single manager and stop sensors whenever the gravity stage leaves view.
final class KaraokeSpaceMotion {
    static let shared = KaraokeSpaceMotion()
    private var manager: CMMotionManager?
    private weak var owner: UIView?
    private var filtered = CGVector.zero
    private var filteredSpin: CGFloat = 0
    private var filteredDepth: CGFloat = 0

    func start(for view: UIView) {
        if owner === view { return }
        owner = view
        // A track transition can briefly show two stages; share the running sensor.
        if manager != nil { return }
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let manager = CMMotionManager()
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        self.manager = manager
        manager.startDeviceMotionUpdates()
    }

    func stop(for view: UIView) {
        guard owner == nil || owner === view else { return }
        stop()
    }

    private func stop() {
        manager?.stopDeviceMotionUpdates()
        manager = nil
        owner = nil
        filtered = .zero
        filteredSpin = 0
        filteredDepth = 0
    }

    func sample(for view: UIView, delta: CGFloat) -> (acceleration: CGVector, spin: CGFloat, depth: CGFloat) {
        guard owner === view, let motion = manager?.deviceMotion else { return (.zero, 0, 0) }
        let acceleration = motion.userAcceleration
        guard acceleration.x.isFinite, acceleration.y.isFinite, acceleration.z.isFinite,
              motion.rotationRate.z.isFinite else { return (.zero, 0, 0) }
        let x = CGFloat(acceleration.x), y = CGFloat(acceleration.y)
        let screen: CGVector
        switch view.window?.windowScene?.interfaceOrientation ?? .portrait {
        case .landscapeLeft: screen = CGVector(dx: y, dy: x)
        case .landscapeRight: screen = CGVector(dx: -y, dy: -x)
        case .portraitUpsideDown: screen = CGVector(dx: -x, dy: y)
        default: screen = CGVector(dx: x, dy: -y)
        }
        let blend = 1 - pow(CGFloat(0.82), delta * 60)
        filtered.dx += (screen.dx - filtered.dx) * blend
        filtered.dy += (screen.dy - filtered.dy) * blend
        filteredSpin += (CGFloat(motion.rotationRate.z) - filteredSpin) * blend
        filteredDepth += (CGFloat(acceleration.z) - filteredDepth) * blend
        return (CGVector(dx: abs(filtered.dx) < 0.015 ? 0 : min(4, max(-4, filtered.dx)),
                         dy: abs(filtered.dy) < 0.015 ? 0 : min(4, max(-4, filtered.dy))),
                min(12, max(-12, filteredSpin)),
                abs(filteredDepth) < 0.015 ? 0 : min(4, max(-4, filteredDepth)))
    }
}
