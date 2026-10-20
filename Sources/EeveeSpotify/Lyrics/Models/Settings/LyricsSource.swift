import Foundation

enum LyricsSource: Int, CaseIterable, CustomStringConvertible {
    case genius
    case lrclib
    case musixmatch
    case petit
    case notReplaced
    case spicylyrics
    case appleMusic
    case spotify
    case netease

    public static var allCases: [LyricsSource] {
        return [.spicylyrics, .musixmatch, .appleMusic, .spotify, .lrclib, .netease, .genius, .petit]
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
        }
    }

    var isReplacingLyrics: Bool { self != .notReplaced }

    /// The custom lyrics view needs time-synced lyrics; Genius only has plain text.
    var supportsCustomLyricsView: Bool { isReplacingLyrics && self != .genius }

    static var defaultSource: LyricsSource {
        .spicylyrics
    }
}
