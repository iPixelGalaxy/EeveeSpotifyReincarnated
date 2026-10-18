import Orion
import UIKit

struct KaraokeGlobalRotationGroup: HookGroup {}

class SpotifyApplicationRotationHook: ClassHook<UIApplication> {
    typealias Group = KaraokeGlobalRotationGroup
    func supportedInterfaceOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask { .allButUpsideDown }
    @objc(setDelegate:) func setDelegate(_ delegate: AnyObject?) {
        orig.setDelegate(delegate)
        KaraokeRotation.installDelegate(delegate)
    }
}

class SpotifyControllerRotationHook: ClassHook<UIViewController> {
    typealias Group = KaraokeGlobalRotationGroup
    func viewDidLoad() {
        orig.viewDidLoad()
        KaraokeRotation.prepare(target)
    }
    func viewWillAppear(_ animated: Bool) {
        KaraokeRotation.prepare(target)
        orig.viewWillAppear(animated)
    }
}
