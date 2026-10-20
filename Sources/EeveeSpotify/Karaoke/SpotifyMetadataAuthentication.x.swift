import Foundation
import Orion

struct SpotifyMetadataAuthenticationGroup: HookGroup {}

// Observe Spotify's token objects independently of optional Premium/network patches.
// Both selectors were verified on the connected 9.1.90 device.
class SpotifyMetadataTokenHook: ClassHook<NSObject> {
    typealias Group = SpotifyMetadataAuthenticationGroup
    static let targetName = "SPTOauthAccessTokenImpl"
    func accessToken() -> String? {
        let token = orig.accessToken()
        captureSpotifyAccessToken(token)
        return token
    }
}

class SpotifyMetadataTokenBridgeHook: ClassHook<NSObject> {
    typealias Group = SpotifyMetadataAuthenticationGroup
    static let targetName = "_TtC24Connectivity_SessionImplP33_831B98CC28223E431E21CD27ADD20AF222OauthAccessTokenBridge"
    func accessToken() -> String? {
        let token = orig.accessToken()
        captureSpotifyAccessToken(token)
        return token
    }
}

// Preserve token and client-token observation even when response patching is disabled.
class SpotifyMetadataDataLoaderTokenHook: ClassHook<NSObject> {
    typealias Group = SpotifyMetadataAuthenticationGroup
    static let targetName = "SPTDataLoaderService"
    func URLSession(_ session: URLSession, task: URLSessionDataTask, didCompleteWithError error: Error?) {
        captureAccessToken(from: task.currentRequest)
        orig.URLSession(session, task: task, didCompleteWithError: error)
    }
}

class SpotifyMetadataHTTPTokenHook: ClassHook<NSObject> {
    typealias Group = SpotifyMetadataAuthenticationGroup
    static let targetName = "Connectivity_HttpClientKit.HttpClientURLSession"
    func URLSession(_ session: URLSession, task: URLSessionDataTask, didCompleteWithError error: Error?) {
        captureAccessToken(from: task.currentRequest)
        orig.URLSession(session, task: task, didCompleteWithError: error)
    }
}
