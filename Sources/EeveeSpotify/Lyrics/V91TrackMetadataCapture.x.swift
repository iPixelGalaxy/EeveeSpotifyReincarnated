import Foundation

/// Track-scoped values shared by overlapping native and custom lyrics requests.
enum LyricsTrackMetadata {
    private static let lock = NSLock()
    private static var values: [String: (title: String, artist: String)] = [:]
    static func get(_ id: String) -> (title: String, artist: String)? {
        lock.lock(); defer { lock.unlock() }; return values[id]
    }
    static func set(_ id: String, title: String, artist: String) {
        guard !title.isEmpty, !artist.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if values.count >= 16 { values.removeAll() }
        values[id] = (title, artist)
    }
}

/// Called on a lyrics worker, never the UI thread. Uses native metadata rather than the Web API.
func fetchTrackDetails(trackId: String, token: String) -> (title: String, artist: String)? {
    guard !Thread.isMainThread else { return nil }
    let ready = DispatchSemaphore(value: 0), lock = NSLock()
    var result: (title: String, artist: String)?
    let task = SpotifyMobileMetadata.track(trackId) { value in
        lock.lock(); result = value.map { ($0.title, $0.artist) }; lock.unlock(); ready.signal()
    }
    if ready.wait(timeout: .now() + 10) == .timedOut { task?.cancel() }
    lock.lock(); defer { lock.unlock() }; return result
}
