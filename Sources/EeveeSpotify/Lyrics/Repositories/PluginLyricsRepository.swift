import Foundation

/// The plugin's additional providers. Keep word timings from Apple Music, and
/// pass Spotify/NetEase line timings through the existing karaoke bridge.
final class PluginLyricsRepository: LyricsRepository {
    static let appleMusic = PluginLyricsRepository(source: .appleMusic)
    static let spotify = PluginLyricsRepository(source: .spotify)
    static let netease = PluginLyricsRepository(source: .netease)
    private let source: LyricsSource
    private let session: URLSession
    private init(source: LyricsSource) {
        self.source = source
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    private func json(_ url: URL, token: String? = nil) throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:93.0) Gecko/20100101 Firefox/93.0", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("iOS", forHTTPHeaderField: "App-Platform")
        }
        let ready = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(LyricsError.noSuchSong)
        session.dataTask(with: request) { data, response, error in
            defer { ready.signal() }
            if let error { result = .failure(error); return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            result = .success(body)
        }.resume()
        ready.wait()
        return try result.get()
    }
    private func dto(_ lines: [LyricsLineDto], synced: Bool, provider: String, query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        guard !lines.isEmpty else { throw LyricsError.noSuchSong }
        var lines = lines.sorted { ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0) }
        let filled = LyricsUncensorFill.fill(lines: lines.map(\.content), query: query, options: options)
        for index in lines.indices where index < filled.count { lines[index].content = filled[index] }
        return LyricsDto(lines: lines, timeSynced: synced,
                         romanization: lines.map(\.content).canBeRomanized ? .canBeRomanized : .original,
                         providerCredit: provider)
    }
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        switch source {
        case .appleMusic: return try SpicyLyricsRepository.shared.getLyrics(query, options: options, source: .appleMusic)
        case .spotify: return try spotifyLyrics(query, options: options)
        case .netease: return try neteaseLyrics(query, options: options)
        default: throw LyricsError.invalidSource
        }
    }
    private func spotifyLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        guard query.spotifyTrackId.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil,
              let token = spotifyAccessToken,
              let url = URL(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(query.spotifyTrackId)?format=json&vocalRemoval=false&market=from_token"),
              let lyrics = try json(url, token: token)["lyrics"] as? [String: Any],
              let raw = lyrics["lines"] as? [[String: Any]] else { throw LyricsError.noSuchSong }
        let synced = lyrics["syncType"] as? String == "LINE_SYNCED"
        let lines = raw.compactMap { row -> LyricsLineDto? in
            guard let text = row["words"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.range(of: "^[♪♫♬♩\\s]*$", options: .regularExpression) == nil else { return nil }
            let offset = (row["startTimeMs"] as? String).flatMap(Int.init) ?? (row["startTimeMs"] as? NSNumber)?.intValue
            return LyricsLineDto(content: text, offsetMs: synced ? offset : nil)
        }
        let backend = (lyrics["provider"] as? String)?.lowercased()
        return try dto(lines, synced: synced, provider: backend == "musixmatch" ? "Spotify (through Musixmatch)" : "Spotify", query: query, options: options)
    }
    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"\([^)]*\)|\[[^]]*\]|\bfeat\..*$"#, with: "", options: .regularExpression)
            .components(separatedBy: .alphanumerics.inverted).joined()
    }
    private func neteaseLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        var search = URLComponents(string: "https://music.xianqiao.wang/neteaseapiv2/search")!
        search.queryItems = [URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "type", value: "1"),
                             URLQueryItem(name: "keywords", value: "\(query.title) \(query.primaryArtist)")]
        guard let url = search.url, let result = try json(url)["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]], !songs.isEmpty else { throw LyricsError.noSuchSong }
        func score(_ song: [String: Any]) -> Int {
            let title = normalized(song["name"] as? String ?? "") == normalized(query.title)
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let artist = artists.contains { normalized($0) == normalized(query.primaryArtist) }
            return (title ? 3 : 0) + (artist ? 2 : 0)
        }
        guard let song = songs.max(by: { score($0) < score($1) }), let id = song["id"] as? NSNumber,
              let lyricURL = URL(string: "https://music.xianqiao.wang/neteaseapiv2/lyric?id=\(id.stringValue)"),
              let lrc = try json(lyricURL)["lrc"] as? [String: Any], let text = lrc["lyric"] as? String else { throw LyricsError.noSuchSong }
        let tags = try NSRegularExpression(pattern: #"\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        let credits = try NSRegularExpression(pattern: #"^(?:\s?作?\s*词|\s?作?\s*曲|编曲|监制|.*和声|.*录音|.*制作|.*发行|.*混音|lrc|publish|vocal|guitar|program|produce|write|mix).*[:：]"#, options: .caseInsensitive)
        var lines = [LyricsLineDto](), plain = [LyricsLineDto]()
        for row in text.components(separatedBy: .newlines) {
            let range = NSRange(row.startIndex..., in: row)
            let matches = tags.matches(in: row, range: range)
            let content = tags.stringByReplacingMatches(in: row, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, !content.hasPrefix("["), content != "纯音乐, 请欣赏",
                  credits.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) == nil else { continue }
            plain.append(LyricsLineDto(content: content, offsetMs: nil))
            for match in matches {
                func value(_ index: Int) -> String { Range(match.range(at: index), in: row).map { String(row[$0]) } ?? "" }
                let fraction = value(3)
                let ms = (Int(value(1)) ?? 0) * 60_000 + (Int(value(2)) ?? 0) * 1000
                    + (Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0)
                lines.append(LyricsLineDto(content: content, offsetMs: ms))
            }
        }
        return try dto(lines.isEmpty ? plain : lines, synced: !lines.isEmpty, provider: "NetEase", query: query, options: options)
    }
}
