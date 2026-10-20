import Orion
import UIKit

struct KaraokeDJGroup: HookGroup {}
struct KaraokeDJDurationGroup: HookGroup {}

// DJ uses Endless_DJMusicImpl units rather than the regular Now Playing units.
class KaraokeDJHeadHook: ClassHook<UIViewController> {
    typealias Group = KaraokeDJGroup
    static let targetName = "_TtC19Endless_DJMusicImpl25DJMHeadUnitViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        KaraokeOverlayPresenter.prepareDJPlayer(target)
    }
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        KaraokeOverlayPresenter.resumeDJPlayer(target)
    }
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        KaraokeOverlayPresenter.registerDJHead(target)
    }
    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        KaraokeOverlayPresenter.suspendDJPlayer(target)
    }
}

class KaraokeDJFooterHook: ClassHook<UIViewController> {
    typealias Group = KaraokeDJGroup
    static let targetName = "_TtC19Endless_DJMusicImpl27DJMFooterUnitViewController"
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if #available(iOS 15.0, *), let view = target.viewIfLoaded {
            KaraokeFooterButton.attach(to: view, isDJ: true)
        }
    }
}

class KaraokeDJHeaderHook: ClassHook<UIViewController> {
    typealias Group = KaraokeDJGroup
    static let targetName = "_TtC19Endless_DJMusicImpl35DJMHeaderElementsUnitViewController"
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerHeader(view) }
    }
}

class KaraokeDJInformationHook: ClassHook<UIViewController> {
    typealias Group = KaraokeDJGroup
    static let targetName = "_TtC19Endless_DJMusicImpl32DJMInformationUnitViewController"
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerInformation(view) }
    }
}

class KaraokeDJDurationHook: ClassHook<UIViewController> {
    typealias Group = KaraokeDJDurationGroup
    static let targetName = "_TtC19Endless_DJMusicImpl23DJMDurationElementsUnit"
    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let view = target.viewIfLoaded { KaraokeOverlayPresenter.registerDuration(view) }
    }
}

func activateKaraokeDJHooks() {
    let required = [KaraokeDJHeadHook.targetName, KaraokeDJFooterHook.targetName,
                    KaraokeDJHeaderHook.targetName, KaraokeDJInformationHook.targetName]
    guard required.allSatisfy({ (NSClassFromString($0) as? UIViewController.Type) != nil }) else {
        writeDebugLog("[Karaoke][DJ] skipped: controller units unavailable")
        return
    }
    KaraokeDJGroup().activate()
    if (NSClassFromString(KaraokeDJDurationHook.targetName) as? UIViewController.Type) != nil {
        KaraokeDJDurationGroup().activate()
    }
    writeDebugLog("[Karaoke][DJ] native player hooks active")
}
