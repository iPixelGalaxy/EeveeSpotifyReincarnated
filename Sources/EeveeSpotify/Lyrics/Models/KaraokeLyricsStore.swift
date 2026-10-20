import Foundation

/// Holds the most recently parsed karaoke (per-syllable) lyrics, keyed by
/// Spotify track ID. SpicyLyricsRepository populates this as a side effect
/// whenever it parses a Type=="Syllable" response — it's the bridge between
/// the existing LyricsRepository protocol (which only returns flattened
/// LyricsDto, matching Spotify's native line-only protobuf schema) and the
/// custom karaoke overlay view, which needs the richer per-syllable timing
/// that LyricsDto has nowhere to carry.
///
/// Not persisted, not thread-safety-hardened beyond a simple lock — this is
/// just a same-process handoff between "lyrics were fetched" and "the
/// overlay wants to render them," both of which happen on the main app
/// process during normal playback.
/// Holds the most recently parsed karaoke (per-syllable) lyrics, keyed by
/// Spotify track ID. SpicyLyricsRepository populates this as a side effect
/// whenever it parses a Type=="Syllable" response — it's the bridge between
/// the existing LyricsRepository protocol (which only returns flattened
/// LyricsDto, matching Spotify's native line-only protobuf schema) and the
/// custom karaoke overlay view, which needs the richer per-syllable timing
/// that LyricsDto has nowhere to carry.
///
/// Not persisted, not thread-safety-hardened beyond a simple lock — this is
/// just a same-process handoff between "lyrics were fetched" and "the
/// overlay wants to render them," both of which happen on the main app
/// process during normal playback.
final class KaraokeLyricsStore {
    static let shared = KaraokeLyricsStore()

    private let lock = NSLock()
    private var cache: [String: KaraokeLyricsDto] = [:]
    private var revisions: [String: UInt64] = [:]
    private var revision: UInt64 = 0
    private var order: [String] = []
    private let capacity = 8

    private init() {}

    @discardableResult func set(trackId: String, source: LyricsSource, lyrics: KaraokeLyricsDto) -> KaraokeLyricsDto {
        guard !trackId.isEmpty, source == UserDefaults.lyricsSource else { return lyrics }
        lock.lock()
        cache[trackId] = lyrics
        revision &+= 1; revisions[trackId] = revision
        order.removeAll { $0 == trackId }
        order.append(trackId)
        if order.count > capacity { let id = order.removeFirst(); cache[id] = nil; revisions[id] = nil }
        lock.unlock()
        notify()
        return lyrics
    }

    /// Drops a track's entry. Called before every fresh fetch so a result from an
    /// earlier source (or an earlier attempt) can never keep the button alive
    /// for a track whose current fetch found nothing.
    func remove(trackId: String) {
        guard !trackId.isEmpty else { return }
        lock.lock()
        let hadEntry = cache.removeValue(forKey: trackId) != nil
        revisions[trackId] = nil
        order.removeAll { $0 == trackId }
        lock.unlock()
        if hadEntry { notify() }
    }

    func lyrics(forTrackId trackId: String) -> KaraokeLyricsDto? {
        lock.lock()
        defer { lock.unlock() }
        return cache[trackId]
    }
    func snapshot(forTrackId trackId: String) -> (lyrics: KaraokeLyricsDto, revision: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let lyrics = cache[trackId], let revision = revisions[trackId] else { return nil }
        return (lyrics, revision)
    }

    func clear() {
        lock.lock()
        cache = [:]
        order = []
        lock.unlock()
        notify()
    }

    func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .eeveeKaraokeLyricsChanged, object: nil) }
    }
}
