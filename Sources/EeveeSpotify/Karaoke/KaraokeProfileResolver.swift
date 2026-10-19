import Foundation

/// Same public ttmlProfile query as Spicy's IframeProfileModal.tsx.
/// Resolve usernames and display-name casing together, with Spicy's cache and retry lifetimes.
@available(iOS 15.0, *)
actor KaraokeProfileResolver {
    static let shared = KaraokeProfileResolver()
    private var cache: [String: (profile: LyricsContributorIdentity?, expires: Date)] = [:]
    private var pending: [String: Task<LyricsContributorIdentity?, Never>] = [:]

    func identity(profileURL: String?) async -> LyricsContributorIdentity? {
        guard let profileURL, let url = URL(string: profileURL), url.scheme == "https",
              url.host == "spicylyrics.org", url.pathComponents.count == 3,
              url.pathComponents[1] == "uid" else { return nil }
        let id = url.lastPathComponent
        if let entry = cache[id], entry.expires > Date() { return entry.profile }
        if let request = pending[id] { return await request.value }
        let request = Task { await Self.fetch(id: id) }
        pending[id] = request
        let profile = await request.value
        pending[id] = nil
        cache[id] = (profile, Date().addingTimeInterval(profile == nil ? 30 : 300))
        return profile
    }

    private static func fetch(id: String) async -> LyricsContributorIdentity? {
        var request = URLRequest(url: URL(string: "https://api.spicylyrics.org/query")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("2", forHTTPHeaderField: "X-mode")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = "unknown"
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "queries": [["operation": "ttmlProfile", "variables": ["userId": id, "referrer": "lyricsCreditsView"]]],
            "client": ["version": version]
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jobs = body["queries"] as? [[String: Any]],
                  let result = jobs.first?["result"] as? [String: Any],
                  let value = result["data"] as? [String: Any],
                  let profile = value["profile"] as? [String: Any],
                  let details = profile["data"] as? [String: Any] else { return nil }
            let user = details["user"] as? [String: Any]
            let username = [details["username"], user?["username"]].lazy.compactMap {
                LyricsContributorIdentity.nonEmpty($0 as? String)
            }.first
            let displayKeys = ["globalName", "global_name", "displayName", "display_name"]
            let displayName = (displayKeys.map { details[$0] } + displayKeys.map { user?[$0] }).lazy.compactMap {
                LyricsContributorIdentity.nonEmpty($0 as? String)
            }.first
            if let username { return LyricsContributorIdentity(username: username, displayName: displayName) }
        } catch {
            writeDebugLog("[Karaoke] optional contributor profile lookup unavailable")
        }
        return nil
    }
}
