import UIKit
import ObjectiveC.runtime

/// Spotify-wide rotation, including controllers which override UIKit's default mask.
enum KaraokeRotation {
    private static var active = false
    private static var patchedClasses = Set<ObjectIdentifier>()
    private static var patchedDelegates = Set<ObjectIdentifier>()

    static func activate() {
        guard !active else { return }
        active = true
        KaraokeGlobalRotationGroup().activate()
        install(on: UIViewController.self)
        DispatchQueue.main.async {
            installDelegate(UIApplication.shared.delegate)
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows {
                    if let root = window.rootViewController { prepareTree(root) }
                }
                if #available(iOS 16.0, *) {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown)) { error in
                        writeDebugLog("[Rotation] \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    static func prepare(_ controller: UIViewController) {
        var current: UIViewController? = controller
        while let item = current {
            let type = Swift.type(of: item)
            let changed = !patchedClasses.contains(ObjectIdentifier(type))
            install(on: type)
            if changed, #available(iOS 16.0, *) { item.setNeedsUpdateOfSupportedInterfaceOrientations() }
            current = item.parent
        }
    }

    private static func prepareTree(_ controller: UIViewController) {
        prepare(controller)
        controller.children.forEach(prepareTree)
        if let presented = controller.presentedViewController { prepareTree(presented) }
    }

    // Existing lyric-player callers must no longer force portrait when lyrics close.
    static func update(controller: UIViewController?, enabled _: Bool) {
        if let controller { prepare(controller) }
    }

    static func installDelegate(_ delegate: AnyObject?) {
        guard let delegate, let type = object_getClass(delegate),
              patchedDelegates.insert(ObjectIdentifier(type)).inserted else { return }
        let selector = NSSelectorFromString("application:supportedInterfaceOrientationsForWindow:")
        guard let method = class_getInstanceMethod(type, selector) else { return }
        let block: @convention(block) (AnyObject, UIApplication, UIWindow?) -> UInt = { _, _, _ in
            UIInterfaceOrientationMask.allButUpsideDown.rawValue
        }
        class_replaceMethod(type, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    private static func install(on type: AnyClass) {
        guard patchedClasses.insert(ObjectIdentifier(type)).inserted else { return }
        let mask = #selector(getter: UIViewController.supportedInterfaceOrientations)
        if let method = class_getInstanceMethod(type, mask) {
            let block: @convention(block) (UIViewController) -> UInt = { _ in UIInterfaceOrientationMask.allButUpsideDown.rawValue }
            class_replaceMethod(type, mask, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        let autorotate = #selector(getter: UIViewController.shouldAutorotate)
        if let method = class_getInstanceMethod(type, autorotate) {
            let block: @convention(block) (UIViewController) -> Bool = { _ in true }
            class_replaceMethod(type, autorotate, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        let preferred = #selector(getter: UIViewController.preferredInterfaceOrientationForPresentation)
        if let method = class_getInstanceMethod(type, preferred) {
            let block: @convention(block) (UIViewController) -> Int = { controller in
                let scene = controller.viewIfLoaded?.window?.windowScene
                    ?? controller.presentingViewController?.viewIfLoaded?.window?.windowScene
                    ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
                let orientation = scene?.interfaceOrientation ?? .portrait
                return (orientation == .unknown ? UIInterfaceOrientation.portrait : orientation).rawValue
            }
            class_replaceMethod(type, preferred, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        let lock = NSSelectorFromString("prefersInterfaceOrientationLocked")
        if let method = class_getInstanceMethod(type, lock) {
            let block: @convention(block) (UIViewController) -> Bool = { _ in false }
            class_replaceMethod(type, lock, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
    }
}
