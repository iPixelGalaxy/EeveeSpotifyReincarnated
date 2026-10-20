import Foundation

/// Plugin scoring: word timings 3, line timings 2, plain text 1. Publish a usable
/// result immediately, then upgrade it as preferred providers finish.
final class AutomaticLyricsRepository: LyricsRepository {
    static let shared = AutomaticLyricsRepository()
    private static let workers: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 6; queue.qualityOfService = .userInitiated; return queue
    }()
    private struct Candidate { let source: LyricsSource; let lyrics: LyricsDto }
    private final class State {
        let lock = NSLock()
        var best: Candidate?
        var closed = false
    }
    static func cancelInactive(trackId: String?) {
        for operation in workers.operations where trackId == nil || operation.name?.hasPrefix(trackId! + ":") != true { operation.cancel() }
        if let trackId {
            SpicyLyricsRepository.shared.cancelInactive(trackId: trackId)
            PluginLyricsRepository.spotify.cancelInactive(trackId: trackId)
            PluginLyricsRepository.netease.cancelInactive(trackId: trackId)
        }
    }
    private func gaps(_ lyrics: LyricsDto) -> Bool {
        guard let rich = lyrics.karaoke else { return false }
        let lines = rich.lines.filter { !$0.isBackground && !$0.isInterlude }.sorted { $0.startMs < $1.startMs }
        return zip(lines, lines.dropFirst()).contains { (300..<5000).contains($0.1.startMs - $0.0.endMs) }
    }
    private func better(_ next: Candidate, than current: Candidate, preferences: LyricsSourcePreferences) -> Bool {
        if next.lyrics.qualityRating != current.lyrics.qualityRating { return next.lyrics.qualityRating > current.lyrics.qualityRating }
        if preferences.prioritizeAppleMusic {
            if next.source == .appleMusic, gaps(next.lyrics) { return true }
            if current.source == .appleMusic, gaps(current.lyrics) { return false }
        }
        return (preferences.order.firstIndex(of: next.source) ?? Int.max) < (preferences.order.firstIndex(of: current.source) ?? Int.max)
    }
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let preferences = UserDefaults.lyricsSourcePreferences, state = State(), group = DispatchGroup()
        let enabled = preferences.enabled
        var jobs = enabled.filter { $0 != .spicylyrics && $0 != .appleMusic }
        if enabled.contains(.spicylyrics) || enabled.contains(.appleMusic) { jobs.insert(.spicylyrics, at: 0) }
        for provider in jobs {
            let operation = BlockOperation(); operation.name = query.spotifyTrackId + ":" + String(provider.rawValue)
            group.enter(); operation.completionBlock = { group.leave() }
            operation.addExecutionBlock { [weak operation] in
                guard let operation, !operation.isCancelled else { return }
                do {
                    var query = query
                    if [.musixmatch, .lrclib, .netease].contains(provider), query.title.isEmpty || query.primaryArtist.isEmpty,
                       let token = spotifyAccessToken, let metadata = fetchTrackDetails(trackId: query.spotifyTrackId, token: token) {
                        query.title = metadata.title; query.primaryArtist = metadata.artist
                    }
                    let dto: LyricsDto
                    switch provider {
                    case .spicylyrics:
                        dto = try SpicyLyricsRepository.shared.getLyrics(query, options: options, source: .spicylyrics, isCancelled: { operation.isCancelled })
                    case .musixmatch: dto = try MusixmatchLyricsRepository.shared.getLyrics(query, options: options)
                    case .spotify: dto = try PluginLyricsRepository.spotify.getLyrics(query, options: options)
                    case .lrclib: dto = try LrclibLyricsRepository.shared.getLyrics(query, options: options)
                    case .netease: dto = try PluginLyricsRepository.netease.getLyrics(query, options: options)
                    default: throw LyricsError.invalidSource
                    }
                    let actual: LyricsSource = provider == .spicylyrics && (dto.karaoke?.providerName == "Apple Music" || dto.providerCredit == "Apple Music") ? .appleMusic : provider
                    guard enabled.contains(actual), !dto.lines.isEmpty, !operation.isCancelled else { return }
                    let candidate = Candidate(source: actual, lyrics: dto)
                    state.lock.lock(); defer { state.lock.unlock() }
                    guard !state.closed, state.best.map({ self.better(candidate, than: $0, preferences: preferences) }) ?? true else { return }
                    state.best = candidate
                    let playing = KaraokePlaybackTracker.shared.playerReportedTrackId()
                    if (playing == nil || playing == query.spotifyTrackId), UserDefaults.lyricsSource == .automatic,
                       UserDefaults.lyricsSourcePreferences == preferences,
                       let karaoke = dto.karaoke ?? KaraokeLyricsDto.lineSynced(from: dto, providerName: dto.providerCredit ?? actual.description) {
                        KaraokeLyricsStore.shared.set(trackId: query.spotifyTrackId, source: .automatic, lyrics: karaoke)
                    }
                } catch { /* A failed provider must not block the others. */ }
            }
            Self.workers.addOperation(operation)
        }
        _ = group.wait(timeout: .now() + 40)
        state.lock.lock(); state.closed = true; let best = state.best; state.lock.unlock()
        for operation in Self.workers.operations where operation.name?.hasPrefix(query.spotifyTrackId + ":") == true { operation.cancel() }
        guard let best else { throw LyricsError.noSuchSong }
        guard UserDefaults.lyricsSourcePreferences == preferences, UserDefaults.lyricsSource == .automatic else { throw URLError(.cancelled) }
        return best.lyrics
    }
}
