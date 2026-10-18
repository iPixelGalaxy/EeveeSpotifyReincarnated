import SwiftUI

/// Keeps the open custom lyrics view in step with the playing track. When a song ends and the
/// next one starts, it swaps in that song's lyrics. Slow or failed loads show a retry state.
@available(iOS 15.0, *)
final class KaraokeLyricsViewModel: ObservableObject {
    @Published private(set) var trackId: String?
    @Published private(set) var lyrics: KaraokeLyricsDto?
    @Published private(set) var layouts: [KaraokeLineLayout] = []

    private var observer: NSObjectProtocol?
    private var retryWork: DispatchWorkItem?
    private var attempts = 0

    @Published private(set) var loadingFailed = false

    private let maxAttempts = 45
    private let retryInterval: TimeInterval = 2.0

    init(trackId: String?, lyrics: KaraokeLyricsDto?) {
        self.trackId = trackId
        apply(lyrics)
        observer = NotificationCenter.default.addObserver(
            forName: .eeveeKaraokeLyricsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
        sync()
    }

    deinit {
        retryWork?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func apply(_ lyrics: KaraokeLyricsDto?) {
        let displayLyrics = lyrics?.addingInterludes()
        self.lyrics = displayLyrics
        let songIsRTL = displayLyrics?.isRTL ?? false
        layouts = displayLyrics?.lines.map { line in
            let direction = line.strongDirection
            return KaraokeLineLayout(words: line.words, isRTL: direction.map { $0 == .rightToLeft } ?? songIsRTL,
                                     startMs: line.startMs, endMs: line.endMs, isInterlude: line.isInterlude)
        } ?? []
    }

    private func sync() {
        // The player's own track, not the one a lyrics request last named: Spotify also loads
        // lyrics for songs that haven't started yet.
        let tracker = KaraokePlaybackTracker.shared
        guard let playing = tracker.playerReportedTrackId() ?? tracker.currentTrackId() else { return }

        let stored = KaraokeLyricsStore.shared.lyrics(forTrackId: playing)
        if playing != trackId {
            retryWork?.cancel()
            retryWork = nil
            attempts = 0
            loadingFailed = false
            trackId = playing
            apply(stored)
        } else {
            apply(stored)
        }

        if lyrics == nil {
            fetchMissingLyrics()
        } else {
            loadingFailed = false
            retryWork?.cancel()
            retryWork = nil
        }
    }

    func retry() {
        if let trackId {
            LyricsFetchCache.shared.retry(trackId: trackId, source: UserDefaults.lyricsSource)
        }
        retryWork?.cancel()
        retryWork = nil
        attempts = 0
        loadingFailed = false
        sync()
    }

    private func fetchMissingLyrics() {
        guard retryWork == nil, let trackId else { return }
        guard attempts < maxAttempts else {
            writeDebugLog("[Karaoke] no lyrics for \(trackId) after \(attempts) checks")
            loadingFailed = true
            return
        }
        attempts += 1
        writeDebugLog("[Karaoke] track changed to \(trackId) with the custom lyrics view open, fetching lyrics (attempt \(attempts))")
        let fetch = lyricsFetch(trackId: trackId)
        if fetch.result != nil {
            // Completion without timed data is a real failure, not another slow request.
            loadingFailed = true
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.retryWork = nil
            self?.sync()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval, execute: work)
    }
}
