import Foundation

/// Prefer the player's album metadata, then resolve a missing year without blocking playback.
final class KaraokeReleaseYear {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>(); cache.countLimit = 128; return cache
    }()
    private(set) var year: String?
    var changed: (() -> Void)?
    private var track: String?
    private var attempted = false
    private var generation = 0
    private var task: URLSessionDataTask?

    static func parse(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 4 || (value.count > 4 && ["-", "/"].contains(String(value.dropFirst(4).prefix(1)))),
              let number = Int(value.prefix(4)), (1000...2999).contains(number) else { return nil }
        return String(number)
    }
    private func setYear(_ value: String?) {
        guard year != value else { return }
        year = value; changed?()
    }
    func update(track id: String?, nativeYear: String?, enabled: Bool) {
        if track != id {
            generation += 1; task?.cancel(); task = nil
            track = id; attempted = false; setYear(nil)
        }
        guard enabled, let id else { task?.cancel(); task = nil; attempted = false; return }
        if let year = Self.parse(nativeYear) {
            if task != nil { generation += 1; task?.cancel(); task = nil }
            Self.cache.setObject(year as NSString, forKey: id as NSString)
            setYear(year); return
        }
        if let cached = Self.cache.object(forKey: id as NSString) { setYear(cached as String); return }
        guard !attempted, let token = spotifyAccessToken,
              let url = URL(string: "https://api.spotify.com/v1/tracks/\(id)") else { return }
        attempted = true
        let key = generation
        var request = URLRequest(url: url); request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let album = json["album"] as? [String: Any], let year = Self.parse(album["release_date"] as? String) else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == key, self.track == id else { return }
                Self.cache.setObject(year as NSString, forKey: id as NSString)
                self.task = nil; self.setYear(year)
            }
        }
        task?.resume()
    }
    func stop() { generation += 1; task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
