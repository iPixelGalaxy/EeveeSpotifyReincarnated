import UIKit
import ObjectiveC.runtime

/// Allow rotation only while the embedded lyric player owns this window.
enum KaraokeRotation {
    private static weak var window: UIWindow?
    private static var patchedClasses = Set<ObjectIdentifier>()
    private static var generation = 0

    static func applicationMask(for candidate: UIWindow?) -> UIInterfaceOrientationMask? {
        if let window, candidate == nil || candidate === window { return .allButUpsideDown }
        // Preserve native delegate policies, including any fullscreen video support.
        let delegateHandlesRotation = UIApplication.shared.delegate?.responds(to: NSSelectorFromString("application:supportedInterfaceOrientationsForWindow:")) == true
        return UIDevice.current.userInterfaceIdiom == .phone && !delegateHandlesRotation ? .portrait : nil
    }

    static func update(controller: UIViewController?, enabled: Bool) {
        let next = enabled ? controller?.viewIfLoaded?.window : nil
        guard window !== next else { return }
        let previous = window
        window = next
        generation += 1
        let token = generation
        guard let target = next ?? previous else { return }
        var controllers = [UIViewController]()
        var root = target.rootViewController
        while let current = root { controllers.append(current); root = current.presentedViewController }
        var parent = controller
        while let current = parent { controllers.append(current); parent = current.parent }
        if enabled { controllers.forEach { install(on: type(of: $0)) } }
        if #available(iOS 16.0, *) {
            controllers.forEach { $0.setNeedsUpdateOfSupportedInterfaceOrientations() }
            DispatchQueue.main.async { [weak target] in
                guard generation == token, let scene = target?.windowScene else { return }
                // Let iPad retain its native orientation when the lyric player closes.
                guard enabled || UIDevice.current.userInterfaceIdiom == .phone else { return }
                let mask: UIInterfaceOrientationMask
                switch enabled ? UIDevice.current.orientation : .portrait {
                case .landscapeLeft: mask = .landscapeRight
                case .landscapeRight: mask = .landscapeLeft
                case .portrait, .portraitUpsideDown: mask = .portrait
                default:
                    switch scene.interfaceOrientation {
                    case .landscapeLeft: mask = .landscapeLeft
                    case .landscapeRight: mask = .landscapeRight
                    default: mask = .portrait
                    }
                }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                    writeDebugLog("[Karaoke][rotation] \(error.localizedDescription)")
                }
            }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private static func install(on type: AnyClass) {
        guard patchedClasses.insert(ObjectIdentifier(type)).inserted else { return }
        let maskSelector = #selector(getter: UIViewController.supportedInterfaceOrientations)
        if let method = class_getInstanceMethod(type, maskSelector) {
            let original = method_getImplementation(method)
            let block: @convention(block) (UIViewController) -> UInt = { controller in
                if let window, controller.viewIfLoaded?.window === window { return UIInterfaceOrientationMask.allButUpsideDown.rawValue }
                typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
                return unsafeBitCast(original, to: Getter.self)(controller, maskSelector)
            }
            class_replaceMethod(type, maskSelector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        let rotateSelector = #selector(getter: UIViewController.shouldAutorotate)
        if let method = class_getInstanceMethod(type, rotateSelector) {
            let original = method_getImplementation(method)
            let block: @convention(block) (UIViewController) -> Bool = { controller in
                if let window, controller.viewIfLoaded?.window === window { return true }
                typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                return unsafeBitCast(original, to: Getter.self)(controller, rotateSelector)
            }
            class_replaceMethod(type, rotateSelector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
    }
}
