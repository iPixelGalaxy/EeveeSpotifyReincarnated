import Orion
import Foundation
import ObjectiveC.runtime

struct RemotePlaybackProtectionGroup: HookGroup {}

// Spotify's predictive activation service pulls playback on page changes. Manual
// Play and Connect commands go through separate player/Connect transfer APIs.
class PredictiveConnectActivationHook: ClassHook<NSObject> {
    typealias Group = RemotePlaybackProtectionGroup
    static let targetName = "_TtC42DevicePredictability_ConnectActivationImpl28ConnectActivationServiceImpl"

    @objc(load) func load() {
        writeDebugLog("[Connect] automatic device activation disabled; preserve active device")
    }

    @objc(currentPageViewUpdated:) func currentPageViewUpdated(_ page: AnyObject?) {}
}

func activateRemotePlaybackProtection() {
    guard let target = NSClassFromString(PredictiveConnectActivationHook.targetName),
          class_getInstanceMethod(target, NSSelectorFromString("load")) != nil,
          class_getInstanceMethod(target, NSSelectorFromString("currentPageViewUpdated:")) != nil else { return }
    RemotePlaybackProtectionGroup().activate()
}
