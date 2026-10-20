import Foundation

/// Prefer the player's album metadata, then resolve a missing year without blocking playback.
final class KaraokeReleaseYear {
    private(set) var year: String?
    var changed: (() -> Void)?
    private var track: String?
    private var attempts = 0
    private var token: String?
    private var nextAttempt = Date.distantPast
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
    func update(track id: String?, nativeYear: String?, albumURI: String? = nil, enabled: Bool) {
        if track != id {
            stop(); track = id; attempts = 0; nextAttempt = .distantPast; setYear(nil)
        }
        guard enabled, let id else { stop(); return }
        if let value = Self.parse(nativeYear) { stop(); setYear(value); return }
        guard year == nil, task == nil, let currentToken = spotifyAccessToken else { return }
        if token != currentToken { token = currentToken; attempts = 0; nextAttempt = .distantPast }
        guard attempts < 4, Date() >= nextAttempt else { return }
        attempts += 1
        nextAttempt = Date().addingTimeInterval(12)
        let key = generation
        func finish(_ value: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == key, self.track == id else { return }
                self.task = nil
                if let value { self.setYear(value) }
                else { self.nextAttempt = Date().addingTimeInterval(min(30, Double(self.attempts * 3))) }
            }
        }
        if let albumURI {
            task = SpotifyMobileMetadata.albumYear(albumURI, completion: finish)
        } else {
            task = SpotifyMobileMetadata.track(id) { [weak self] info in
                guard let info else { finish(nil); return }
                if let year = info.year { finish(year); return }
                DispatchQueue.main.async {
                    guard let self, self.generation == key, self.track == id, let album = info.albumURI else { finish(nil); return }
                    self.task = SpotifyMobileMetadata.albumYear(album, completion: finish)
                }
            }
        }
    }
    func stop() { generation += 1; task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
