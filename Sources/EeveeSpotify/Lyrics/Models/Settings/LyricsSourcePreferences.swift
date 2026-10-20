import Foundation

struct LyricsSourcePreferences: Codable, Hashable {
    var order: [LyricsSource] = [.spicylyrics, .musixmatch, .appleMusic, .spotify, .lrclib, .netease]
    var disabled: [LyricsSource] = [.lrclib, .netease]
    var prioritizeAppleMusic = true
    var enabled: [LyricsSource] { order.filter { !disabled.contains($0) } }
}

extension UserDefaults {
    @UserDefault(key: "lyricsSourcePreferences", defaultValue: LyricsSourcePreferences())
    static var lyricsSourcePreferences
}
