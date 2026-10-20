import Foundation

extension UserDefaults {
    private static let lyricsSourceKey = "lyricsSource"
    
    static var lyricsSource: LyricsSource {
        get {
            if !container.bool(forKey: "lyricsSourcesManagerMigrated") {
                let old = (container.object(forKey: lyricsSourceKey) as? Int).flatMap(LyricsSource.init(rawValue:))
                if old != .notReplaced { container.set(LyricsSource.automatic.rawValue, forKey: lyricsSourceKey) }
                container.set(true, forKey: "lyricsSourcesManagerMigrated")
            }
            if let rawValue = container.object(forKey: lyricsSourceKey) as? Int {
                return LyricsSource(rawValue: rawValue) ?? .defaultSource
            }

            return LyricsSource.defaultSource
        }
        set (newSource) {
            container.set(newSource.rawValue, forKey: lyricsSourceKey)
        }
    }
}
