import Foundation

/// Same public ttmlProfile query as Spicy's IframeProfileModal.tsx.
/// Names refresh independently, so credits never wait on this optional request.
@available(iOS 15.0, *)
actor KaraokeProfileResolver {
    static let shared = KaraokeProfileResolver()
    private var cache: [String: (name: String?, expires: Date)] = [:]
    private var pending: [String: Task<String?, Never>] = [:]

    func username(profileURL: String?) async -> String? {
        guard let profileURL, let url = URL(string: profileURL), url.scheme == "https",
              url.host == "spicylyrics.org", url.pathComponents.count == 3,
              url.pathComponents[1] == "uid" else { return nil }
        let id = url.lastPathComponent
        if let entry = cache[id], entry.expires > Date() { return entry.name }
        if let request = pending[id] { return await request.value }
        let request = Task { await Self.fetch(id: id) }
        pending[id] = request
        let name = await request.value
        pending[id] = nil
        cache[id] = (name, Date().addingTimeInterval(name == nil ? 30 : 300))
        return name
    }

    private static func fetch(id: String) async -> String? {
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
            for candidate in [details["username"], user?["username"]] {
                if let name = (candidate as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    return name
                }
            }
        } catch {
            writeDebugLog("[Karaoke] optional contributor profile lookup unavailable")
        }
        return nil
    }
}
