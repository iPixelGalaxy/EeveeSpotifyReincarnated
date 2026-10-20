import Foundation

/// Shared result, completed exactly once even when cancellation races a response.
final class LyricsFetch {
    private let group = DispatchGroup(), lock = NSLock()
    private var storedResult: Result<Lyrics, Error>?
    private var storedKaraoke: KaraokeLyricsDto?
    private var callbacks: [(Result<Lyrics, Error>) -> Void] = []
    init() { group.enter() }
    var result: Result<Lyrics, Error>? { lock.lock(); defer { lock.unlock() }; return storedResult }
    func finish(_ result: Result<Lyrics, Error>, karaoke: KaraokeLyricsDto? = nil) {
        lock.lock()
        guard storedResult == nil else { lock.unlock(); return }
        storedResult = result; storedKaraoke = karaoke; let handlers = callbacks; callbacks.removeAll(); lock.unlock()
        group.leave()
        DispatchQueue.main.async { handlers.forEach { $0(result) } }
    }
    func observe(_ callback: @escaping (Result<Lyrics, Error>) -> Void) {
        lock.lock()
        if let result = storedResult { lock.unlock(); DispatchQueue.main.async { callback(result) } }
        else { callbacks.append(callback); lock.unlock() }
    }
    func wait(timeout: TimeInterval) -> Bool { group.wait(timeout: .now() + timeout) == .success }
    func restoreKaraoke(trackId: String, source: LyricsSource) {
        lock.lock(); let lyrics = storedKaraoke; lock.unlock()
        if let lyrics, KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) == nil {
            KaraokeLyricsStore.shared.set(trackId: trackId, source: source, lyrics: lyrics)
        }
    }
}

final class LyricsFetchCache {
    static let shared = LyricsFetchCache()
    private struct Pending { let fetch: LyricsFetch; let operation: BlockOperation }
    private let lock = NSLock()
    private let workers: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .userInitiated; return queue
    }()
    private var pending: [String: Pending] = [:]
    private var completed: [String: (fetch: LyricsFetch, date: Date)] = [:]
    private var generation = 0
    private func cancel(_ values: [Pending]) {
        for value in values { value.operation.cancel(); value.fetch.finish(.failure(URLError(.cancelled))) }
    }
    func retry(trackId: String, source: LyricsSource) {
        let key = "\(source.rawValue):\(trackId)"
        lock.lock(); completed.removeValue(forKey: key); let old = pending.removeValue(forKey: key); lock.unlock()
        if let old { cancel([old]) }
    }
    func clear() {
        lock.lock(); generation += 1; let old = Array(pending.values); pending.removeAll(); completed.removeAll(); lock.unlock()
        cancel(old)
        AutomaticLyricsRepository.cancelInactive(trackId: nil)
    }
    func prioritize(trackId: String) {
        lock.lock()
        let oldKeys = pending.keys.filter { !$0.hasSuffix(":" + trackId) }
        let old = oldKeys.compactMap { pending.removeValue(forKey: $0) }
        lock.unlock(); cancel(old)
        AutomaticLyricsRepository.cancelInactive(trackId: trackId)
    }
    func request(trackId: String, source: LyricsSource, load: @escaping () throws -> Lyrics) -> LyricsFetch {
        let key = "\(source.rawValue):\(trackId)"
        lock.lock()
        completed = completed.filter {
            let lifetime: TimeInterval
            if case .success? = $0.value.fetch.result { lifetime = 300 } else { lifetime = 10 }
            return Date().timeIntervalSince($0.value.date) < lifetime
        }
        if let existing = completed[key]?.fetch ?? pending[key]?.fetch {
            lock.unlock(); existing.restoreKaraoke(trackId: trackId, source: source); return existing
        }
        let fetch = LyricsFetch(), operation = BlockOperation(), requestGeneration = generation
        pending[key] = Pending(fetch: fetch, operation: operation); lock.unlock()
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { fetch.finish(.failure(URLError(.cancelled))); return }
            let result = Result { try load() }
            self.lock.lock()
            let current = self.generation == requestGeneration && self.pending[key]?.fetch === fetch && !operation.isCancelled
            if current {
                self.pending.removeValue(forKey: key); self.completed[key] = (fetch, Date())
                if self.completed.count > 8, let oldest = self.completed.min(by: { $0.value.date < $1.value.date })?.key { self.completed.removeValue(forKey: oldest) }
            }
            self.lock.unlock()
            fetch.finish(current ? result : .failure(URLError(.cancelled)),
                         karaoke: current ? KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) : nil)
        }
        workers.addOperation(operation)
        return fetch
    }
}
