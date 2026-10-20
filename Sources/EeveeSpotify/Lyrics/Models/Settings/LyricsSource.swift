import Foundation

enum LyricsSource: Int, Codable, CaseIterable, CustomStringConvertible {
    case genius
    case lrclib
    case musixmatch
    case petit
    case notReplaced
    case spicylyrics
    case appleMusic
    case spotify
    case netease
    case automatic

    public static var allCases: [LyricsSource] {
        return [.automatic, .spicylyrics, .musixmatch, .appleMusic, .spotify, .lrclib, .netease, .genius, .petit]
    }

    var description: String {
        switch self {
        case .genius:       return "Genius"
        case .lrclib:       return "LRCLIB"
        case .musixmatch:   return "Musixmatch"
        case .petit:        return "PetitLyrics"
        case .notReplaced:  return "Spotify"
        case .spicylyrics:  return "SpicyLyrics"
        case .appleMusic:   return "Apple Music"
        case .spotify:     return "Spotify"
        case .netease:     return "NetEase"
        case .automatic:   return "lyrics_sources_automatic".localized
        }
    }

    var isReplacingLyrics: Bool { self != .notReplaced }

    /// The custom lyrics view needs time-synced lyrics; Genius only has plain text.
    var supportsCustomLyricsView: Bool { isReplacingLyrics && self != .genius }

    static var defaultSource: LyricsSource {
        .automatic
    }
}
