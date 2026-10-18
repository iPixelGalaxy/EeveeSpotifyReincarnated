import Foundation

/// One provider request shared by Spotify's response hook and the custom lyrics view.
final class LyricsFetch {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var storedResult: Result<Lyrics, Error>?

    init() { group.enter() }

    var result: Result<Lyrics, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func finish(_ result: Result<Lyrics, Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
        group.leave()
    }

    func wait(timeout: TimeInterval) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }
}

final class LyricsFetchCache {
    static let shared = LyricsFetchCache()
    private let lock = NSLock()
    private var pending: [String: LyricsFetch] = [:]
    private var completed: [String: (fetch: LyricsFetch, date: Date)] = [:]
    private var generation = 0

    func retry(trackId: String, source: LyricsSource) {
        lock.lock()
        completed.removeValue(forKey: "\(source.rawValue):\(trackId)")
        lock.unlock()
    }

    func clear() {
        lock.lock()
        generation += 1
        pending.removeAll()
        completed.removeAll()
        lock.unlock()
    }

    func request(trackId: String, source: LyricsSource, load: @escaping () throws -> Lyrics) -> LyricsFetch {
        let key = "\(source.rawValue):\(trackId)"
        lock.lock()
        completed = completed.filter {
            let lifetime: TimeInterval
            if case .success? = $0.value.fetch.result { lifetime = 300 } else { lifetime = 10 }
            return Date().timeIntervalSince($0.value.date) < lifetime
        }
        if let existing = completed[key]?.fetch ?? pending[key] {
            lock.unlock()
            return existing
        }
        let fetch = LyricsFetch()
        let requestGeneration = generation
        pending[key] = fetch
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try load() }
            self.lock.lock()
            if self.generation == requestGeneration {
                self.pending.removeValue(forKey: key)
                self.completed[key] = (fetch, Date())
                if self.completed.count > 8,
                   let oldest = self.completed.min(by: { $0.value.date < $1.value.date })?.key {
                    self.completed.removeValue(forKey: oldest)
                }
            }
            fetch.finish(result)
            self.lock.unlock()
        }
        return fetch
    }
}
