import Orion
import SwiftUI
import MediaPlayer

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }            // 9.1.x-safe subset
struct LyricsErrorHandlingGroup: HookGroup { }  // not activated on 9.1.x

var lyricsState = LyricsLoadingState()

var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()

// Overload for 9.1.6 where we only have track ID from URL
private func loadCustomLyricsForTrackId(_ trackId: String, source requestedSource: LyricsSource) throws -> Lyrics {

    var source = requestedSource

    var currentTitle: String? = nil
    var currentArtist: String? = nil
    var hasMetadata = false

    let needsMetadata = source == .genius || source == .lrclib || source == .petit

    // 1. Use cached metadata if it's for the same track
    if capturedTrackId == trackId, let title = capturedTrackTitle, let artist = capturedArtistName {
        currentTitle = title
        currentArtist = artist
        hasMetadata = true
    }

    // 2. Try statefulPlayer (most reliable on modern Spotify)
    if !hasMetadata {
        if let player = statefulPlayer,
           let track = player.currentTrack() {
            let currentId = track.URI().spt_trackIdentifier()

            if currentId == trackId {
                currentTitle = track.trackTitle()
                currentArtist = track.artistName()
                hasMetadata = true
                capturedTrackId = trackId
                capturedTrackTitle = currentTitle
                capturedArtistName = currentArtist
            }
        }
    }

    // 3. MPNowPlayingInfoCenter — must be read on the main thread.
    // It always describes the playing track, so it must not be used for another track
    // (Spotify also loads lyrics for tracks that aren't playing yet).
    let nowPlayingIsThisTrack = KaraokePlaybackTracker.shared.playerReportedTrackId().map { $0 == trackId } ?? true
    if !hasMetadata && nowPlayingIsThisTrack {
        var npTitle: String? = nil
        var npArtist: String? = nil
        if Thread.isMainThread {
            npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        } else {
            DispatchQueue.main.sync {
                npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
            }
        }
        if let title = npTitle, let artist = npArtist, !title.isEmpty, !artist.isEmpty {
            currentTitle = title
            currentArtist = artist
            hasMetadata = true
            capturedTrackId = trackId
            capturedTrackTitle = title
            capturedArtistName = artist
        }
    }

    // 4. Spotify Web API fallback using captured Bearer token
    if !hasMetadata, let token = spotifyAccessToken {
        if let info = fetchTrackDetails(trackId: trackId, token: token) {
            currentTitle = info.title
            currentArtist = info.artist
            hasMetadata = true
            capturedTrackId = trackId
            capturedTrackTitle = currentTitle
            capturedArtistName = currentArtist
        }
    }

    if needsMetadata && !hasMetadata {
        writeDebugLog("[Lyrics] \(trackId): no title/artist for \(source.description), cannot search")
        throw LyricsError.noSuchSong
    }

    let searchQuery = LyricsSearchQuery(
        title: currentTitle ?? "",
        primaryArtist: currentArtist ?? "",
        spotifyTrackId: trackId
    )
    
    let options = UserDefaults.lyricsOptions
    
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()

    // Keep valid timed lyrics available while a refresh is in flight.
    
    do {
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if let lyricsError = error as? LyricsError {
            lyricsState.fallbackError = lyricsError

            switch lyricsError {
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_unauthorized_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownUnauthorizedPopUp = true
                }
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_restricted_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownRestrictedPopUp = true
                }
            default:
                break
            }
        } else {
            lyricsState.fallbackError = .unknownError
        }

        // Attempt Genius fallback if enabled and the primary source isn't already Genius.
        // Genius requires title + artist to search — only attempt if we have them.
        let canFallbackToGenius = source != .genius
            && UserDefaults.lyricsOptions.geniusFallback
            && !(currentTitle ?? "").isEmpty
            && !(currentArtist ?? "").isEmpty
        if canFallbackToGenius {
            source = .genius
            lyricsDto = try geniusLyricsRepository.getLyrics(searchQuery, options: options)
        } else {
            throw error
        }
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    writeDebugLog("[Lyrics] \(trackId): \(source.description), \(lyricsDto.lines.count) lines, synced=\(lyricsDto.timeSynced)")
    publishLineSyncedKaraokeLyrics(lyricsDto, trackId: searchQuery.spotifyTrackId, source: source)

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

/// Feeds the custom lyrics view for sources that only have line-level timing.
/// Spicy Lyrics publishes its own (word/syllable) data while parsing, so an
/// existing entry for the track is never overwritten.
private func publishLineSyncedKaraokeLyrics(_ dto: LyricsDto, trackId: String, source: LyricsSource) {
    guard source.supportsCustomLyricsView, !trackId.isEmpty,
          KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) == nil else { return }
    guard let karaoke = KaraokeLyricsDto.lineSynced(from: dto, providerName: source.description) else { return }
    KaraokeLyricsStore.shared.set(trackId: trackId, source: source, lyrics: karaoke)
}

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics {
    
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let trackTitle = track.trackTitle()
    let artistName = track.artistName()

    let searchQuery = LyricsSearchQuery(
        title: trackTitle,
        primaryArtist: artistName,
        spotifyTrackId: track.trackIdentifier
    )
    
    let options = UserDefaults.lyricsOptions
    var source = UserDefaults.lyricsSource
    
    // switched to swift 5.8 syntax to compile with Theos on Linux.
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()

    // Keep valid timed lyrics available while a refresh is in flight.
    
    do {
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if let error = error as? LyricsError {
            lyricsState.fallbackError = error
            
            switch error {
                
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_unauthorized_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownUnauthorizedPopUp.toggle()
                }
            
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_restricted_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownRestrictedPopUp.toggle()
                }
                
            default:
                break
            }
        }
        else {
            lyricsState.fallbackError = .unknownError
        }
        
        if source == .genius || !UserDefaults.lyricsOptions.geniusFallback {
            throw error
        }
        
        source = .genius
        repository = GeniusLyricsRepository()
        
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    publishLineSyncedKaraokeLyrics(lyricsDto, trackId: searchQuery.spotifyTrackId, source: source)

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

/// Extracts the Spotify track ID from a `/color-lyrics/v2/track/{trackId}` URL path.
/// Returns nil if the path doesn't match the expected format.
func extractTrackId(from path: String) -> String? {
    guard let range = path.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) else {
        return nil
    }
    let trackId = String(path[range].split(separator: "/").last ?? "")
    return trackId.isEmpty ? nil : trackId
}

// MARK: - Lyrics prefetch
/// Provider changes invalidate both completed responses and in-flight ownership.
func invalidateLyricsForSourceChange() {
    LyricsFetchCache.shared.clear()
    KaraokeLyricsStore.shared.clear()
    MusixmatchLyricsRepository.shared.clearCache()
    writeDebugLog("[Lyrics] provider changed — cleared lyrics caches")
}

func lyricsFetch(trackId: String) -> LyricsFetch {
    let source = UserDefaults.lyricsSource
    return LyricsFetchCache.shared.request(trackId: trackId, source: source) {
        do {
            let lyrics = try loadCustomLyricsForTrackId(trackId, source: source)
            writeDebugLog("[Lyrics] fetch complete for \(trackId)")
            return lyrics
        } catch {
            writeDebugLog("[Lyrics] fetch failed for \(trackId): \(error)")
            throw error
        }
    }
}

/// Repeated callers share one request instead of starting competing provider retries.
func prefetchLyricsIfNeeded(trackId: String) {
    guard !trackId.isEmpty, UserDefaults.lyricsSource.isReplacingLyrics else { return }
    _ = lyricsFetch(trackId: trackId)
}

/// Returns a serialized empty `Lyrics` protobuf payload.
/// Used as a fallback when every lyrics source (including Genius fallback) fails,
/// so we show "no lyrics" instead of leaking Spotify's own Musixmatch response.
func emptyLyricsData(originalLyrics: Lyrics? = nil) -> Data? {
    let emptyDto = LyricsDto(lines: [], timeSynced: false, romanization: .original, translation: nil)
    var lyrics = Lyrics.with {
        $0.data = emptyDto.toSpotifyLyricsData(source: "")
    }
    if let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    return try? lyrics.serializedData()
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    
    // track id from URL path; player objects are nil on 9.1.6
    // path: /color-lyrics/v2/track/{trackId}
    guard let trackIdentifier = extractTrackId(from: originalPath), !trackIdentifier.isEmpty else {
        throw LyricsError.noCurrentTrack
    }

    // The player observer doesn't attach on 9.1.x, so the lyrics request is the current-track signal.
    KaraokePlaybackTracker.shared.updateTrackIdFromLyricsFetch(trackIdentifier)

    if capturedTrackId != trackIdentifier {
        capturedTrackTitle = nil
        capturedArtistName = nil
        capturedTrackId = nil
    }

    let fetch = lyricsFetch(trackId: trackIdentifier)
    // Never block UIKit: metadata fallback can itself need the main queue.
    // The request keeps running and publishes timed lyrics for the overlay.
    if fetch.result == nil {
        guard !Thread.isMainThread, fetch.wait(timeout: 12) else {
            writeDebugLog("[Lyrics] \(trackIdentifier): still loading in background")
            throw LyricsError.noSuchSong
        }
    }
    guard let result = fetch.result else { throw LyricsError.noSuchSong }
    var lyrics = try result.get()

    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    else {
        // no track object on 9.1.6: static color, else background color, else gray
        var color: Color
        
        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        }
        else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else {
            color = Color.gray
        }
        
        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = color.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
    }
    
    return try lyrics.serializedData()
}
