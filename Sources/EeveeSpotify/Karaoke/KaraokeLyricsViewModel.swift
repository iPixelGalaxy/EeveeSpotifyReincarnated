import SwiftUI

/// Keeps the open custom lyrics view in step with the playing track. When a song ends and the
/// next one starts, it swaps in that song's lyrics. Slow or failed loads show a retry state.
@available(iOS 15.0, *)
final class KaraokeLyricsViewModel: ObservableObject {
    @Published private(set) var trackId: String?
    @Published private(set) var lyrics: KaraokeLyricsDto?
    @Published private(set) var layouts: [KaraokeLineLayout] = []

    private var observer: NSObjectProtocol?
    private var optionsObserver: NSObjectProtocol?
    private var retryWork: DispatchWorkItem?
    private var activeFetch: LyricsFetch?
    private var generation = 0
    private var loadedRevision: UInt64?
    private var loadedOptions: KaraokeOptions?
    private var loadedSource: LyricsSource?
    private var loadedPreferences: LyricsSourcePreferences?
    private var timer: Timer?

    @Published private(set) var loadingFailed = false


    init(trackId: String?, lyrics: KaraokeLyricsDto?) {
        self.trackId = trackId
        apply(lyrics)
        observer = NotificationCenter.default.addObserver(
            forName: .eeveeKaraokeLyricsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
        optionsObserver = NotificationCenter.default.addObserver(
            forName: .eeveeKaraokeOptionsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.sync() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        sync()
    }

    deinit {
        retryWork?.cancel(); timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let optionsObserver { NotificationCenter.default.removeObserver(optionsObserver) }
    }

    private func apply(_ lyrics: KaraokeLyricsDto?) {
        let options = UserDefaults.karaokeOptions
        let prepared = options.wordSplittingEnabled
            ? lyrics?.splittingTimedWords(forcedBySpaceGravity: options.spaceGravityMode && !options.experimentalWordSplitting)
            : lyrics
        let displayLyrics = prepared?.addingInterludes()
        self.lyrics = displayLyrics
        let songIsRTL = displayLyrics?.isRTL ?? false
        layouts = displayLyrics?.lines.map { line in
            let direction = line.strongDirection
            let wordEnd = line.words.flatMap { $0 }.map { $0.endMs }.filter { $0 > line.startMs }.max()
            let highlightEnd = line.isInterlude ? line.endMs : min(line.endMs, wordEnd ?? line.endMs)
            return KaraokeLineLayout(words: line.words, isRTL: direction.map { $0 == .rightToLeft } ?? songIsRTL,
                                     startMs: line.startMs, endMs: highlightEnd, isInterlude: line.isInterlude,
                                     isOppositeAligned: line.isOppositeAligned, isBackground: line.isBackground)
        } ?? []
    }

    private func sync() {
        let tracker = KaraokePlaybackTracker.shared
        guard let playing = tracker.playerReportedTrackId() ?? tracker.currentTrackId() else { return }
        let snapshot = KaraokeLyricsStore.shared.snapshot(forTrackId: playing)
        let options = UserDefaults.karaokeOptions
        let source = UserDefaults.lyricsSource, preferences = UserDefaults.lyricsSourcePreferences
        if playing != trackId || loadedSource != source || loadedPreferences != preferences {
            generation += 1; retryWork?.cancel(); retryWork = nil; activeFetch = nil
            loadedRevision = nil; loadedOptions = nil; loadingFailed = false
            trackId = playing
            loadedSource = source; loadedPreferences = preferences
        }
        if snapshot?.revision != loadedRevision || loadedOptions != options {
            loadedRevision = snapshot?.revision; loadedOptions = options
            apply(snapshot?.lyrics)
        }
        if lyrics != nil {
            loadingFailed = false; retryWork?.cancel(); retryWork = nil
        } else if activeFetch == nil && !loadingFailed {
            fetchMissingLyrics()
        }
    }
    func retry() {
        guard let trackId else { return }
        generation += 1; retryWork?.cancel(); retryWork = nil; activeFetch = nil
        LyricsFetchCache.shared.retry(trackId: trackId, source: UserDefaults.lyricsSource)
        loadingFailed = false; sync()
    }
    private func fetchMissingLyrics() {
        guard activeFetch == nil, let id = trackId else { return }
        let key = generation, fetch = lyricsFetch(trackId: id)
        activeFetch = fetch
        fetch.observe { [weak self] _ in
            guard let self, self.generation == key, self.trackId == id else { return }
            self.activeFetch = nil; self.retryWork?.cancel(); self.retryWork = nil
            self.loadingFailed = KaraokeLyricsStore.shared.lyrics(forTrackId: id) == nil
            self.sync()
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == key, self.trackId == id, self.lyrics == nil else { return }
            self.loadingFailed = true; self.retryWork = nil
        }
        retryWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
    }
}
