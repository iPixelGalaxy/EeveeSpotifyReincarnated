import Foundation

/// Uses the public website's profile lookup; /query is restricted to Spicy's own client.
/// Resolve usernames and display-name casing together, without downloading track history.
@available(iOS 15.0, *)
actor KaraokeProfileResolver {
    static let shared = KaraokeProfileResolver()
    private var cache: [String: (profile: LyricsContributorIdentity?, expires: Date)] = [:]
    private var pending: [String: Task<LyricsContributorIdentity?, Never>] = [:]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    nonisolated static func userID(profileURL: String?) -> String? {
        guard let profileURL, let url = URL(string: profileURL), url.scheme == "https",
              url.host == "spicylyrics.org", url.pathComponents.count == 3,
              url.pathComponents[1] == "uid" else { return nil }
        let id = url.lastPathComponent
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return id
    }

    func identity(profileURL: String?) async -> LyricsContributorIdentity? {
        guard let id = Self.userID(profileURL: profileURL) else { return nil }
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
        // The website uses devalue's indexed JSON format for tRPC input/output.
        let input: [Any] = [["id": 1, "includeTracks": 2], id, false]
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let json = String(data: data, encoding: .utf8),
              var components = URLComponents(string: "https://spicylyrics.org/api/trpc/ttml.getTTMLProfile") else { return nil }
        components.queryItems = [URLQueryItem(name: "input", value: json)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("EeveeSpotify", forHTTPHeaderField: "User-Agent")
        eeveeLog("[Karaoke][profile] requesting user=%@", id)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                eeveeLog("[Karaoke][profile] user=%@ HTTP %d", id, status)
                return nil
            }
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = body["result"] as? [String: Any], let value = result["data"] else {
                eeveeLog("[Karaoke][profile] user=%@ invalid response", id)
                return nil
            }
            let payload = ProfilePayload(value)
            guard let profile = payload.field(payload.root, "profile"),
                  let details = payload.field(profile, "data"),
                  payload.field(details, "id") as? String == id else {
                eeveeLog("[Karaoke][profile] user=%@ missing or mismatched profile", id)
                return nil
            }
            let username = LyricsContributorIdentity.nonEmpty(payload.field(details, "username") as? String)
            let displayKeys = ["globalName", "global_name", "displayName", "display_name"]
            let displayName = displayKeys.lazy.compactMap {
                LyricsContributorIdentity.nonEmpty(payload.field(details, $0) as? String)
            }.first
            if let username {
                eeveeLog("[Karaoke][profile] resolved user=%@ username=%@", id, username)
                return LyricsContributorIdentity(username: username, displayName: displayName)
            }
            eeveeLog("[Karaoke][profile] user=%@ missing username", id)
        } catch {
            eeveeLog("[Karaoke][profile] user=%@ failed code=%d", id, (error as NSError).code)
        }
        return nil
    }

    /// Follow only the fields we need, without recursively expanding a shared/cyclic object graph.
    private struct ProfilePayload {
        let root: Any
        private let nodes: [Any]?

        init(_ value: Any) {
            nodes = value as? [Any]
            root = nodes?.first ?? value
        }

        func field(_ value: Any, _ key: String) -> Any? {
            guard let object = value as? [String: Any], let reference = object[key] else { return nil }
            guard let nodes else { return reference }
            guard let index = reference as? Int, nodes.indices.contains(index) else { return nil }
            return nodes[index]
        }
    }
}
