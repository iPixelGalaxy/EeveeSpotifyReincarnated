import Foundation

class SpicyLyricsRepository: LyricsRepository {

    static let shared = SpicyLyricsRepository()
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 15
        config.allowsExpensiveNetworkAccess   = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private let session: URLSession

    private static let apiUrl = "https://api.spicylyrics.org/v1/lyrics/"

    private static func profileName(_ profile: SpicyLyricsJSON?) -> String? {
        for key in ["username", "displayName", "display_name", "globalName", "global_name"] {
            if let value = profile?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func profileURL(_ profile: SpicyLyricsJSON?) -> String? {
        if let id = profile?["id"]?.stringValue,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encoded.isEmpty {
            return "https://spicylyrics.org/uid/\(encoded)"
        }
        if let url = profile?["url"]?.stringValue, URL(string: url)?.scheme == "https" { return url }
        return nil
    }

    // MARK: - Network

    // 503 means the lyrics are still being generated.
    private static let queuedRetryDelays: [TimeInterval] = {
        (0 ..< 5).map { attempt in min(10.0, 2.0 * pow(1.5, Double(attempt))) }
    }()

    private func performQuery(trackId: String, apiKey: String) throws -> (Data, Int) {
        for (attempt, delay) in ([0.0] + SpicyLyricsRepository.queuedRetryDelays).enumerated() {
            if delay > 0 {
                eeveeLog("[EeveeSpotify][SpicyLyrics] %@ queued (503), retrying in %.1fs (attempt %d)", trackId, delay, attempt + 1)
                Thread.sleep(forTimeInterval: delay)
            }
            let (data, httpStatus) = try performRequest(trackId: trackId, apiKey: apiKey)
            if httpStatus != 503 { return (data, httpStatus) }
        }
        eeveeLog("[EeveeSpotify][SpicyLyrics] %@ still queued after all retries", trackId)
        throw LyricsError.noSuchSong
    }

    private func performRequest(trackId: String, apiKey: String) throws -> (Data, Int) {
        guard let url = URL(string: SpicyLyricsRepository.apiUrl + trackId) else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("EeveeSpotify", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseStatus = 0
        var responseError: Error?

        session.dataTask(with: request) { data, response, error in
            responseData = data
            responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            responseError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let error = responseError {
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ network error: %@", trackId, String(describing: error))
            throw error
        }
        guard let data = responseData else {
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ returned no data", trackId)
            throw LyricsError.decodingError
        }
        return (data, responseStatus)
    }

    // MARK: - Parse

    private func parseLyricsData(_ data: Data, httpStatus: Int, trackId: String, query: LyricsSearchQuery, options: LyricsOptions, start: CFAbsoluteTime) throws -> LyricsDto {
        switch httpStatus {
        case 200:
            break
        case 401, 403:
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ key rejected (HTTP %d)", trackId, httpStatus)
            throw LyricsError.invalidSpicyKey
        case 404:
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@: HTTP 404, no lyrics (%.0f ms)", trackId, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            throw LyricsError.noSuchSong
        default:
            let rawBody = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "<non-utf8 \(data.count) bytes>"
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ unexpected HTTP %d: %@", trackId, httpStatus, rawBody)
            throw LyricsError.noSuchSong
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ invalid JSON", trackId)
            throw LyricsError.decodingError
        }

        let root = SpicyLyricsJSON((json as? [String: Any])?["Body"] ?? json)

        guard let type = root["Type"]?.stringValue else {
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ missing Type", trackId)
            throw LyricsError.decodingError
        }

        let dto: LyricsDto
        switch type {
        case "Syllable": dto = parseSyllableLyrics(root, trackId: trackId, query: query, options: options)
        case "Line":     dto = parseLineLyrics(root, trackId: trackId, query: query, options: options)
        case "Static":   dto = parseStaticLyrics(root)
        default:
            eeveeLog("[EeveeSpotify][SpicyLyrics] %@ unknown type '%@'", trackId, type)
            throw LyricsError.decodingError
        }
        eeveeLog("[EeveeSpotify][SpicyLyrics] %@: HTTP %d, %@, %d lines (%.0f ms)",
                 trackId, httpStatus, type, dto.lines.count, (CFAbsoluteTimeGetCurrent() - start) * 1000)
        return dto
    }

    // MARK: Syllable lyrics

    private func parseSyllableLyrics(_ root: SpicyLyricsJSON, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        var karaokeLines = [KaraokeLineDto]()
        var hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            if entry["Type"]?.stringValue == "Interlude" {
                if let start = entry["StartTime"]?.doubleValue, let end = entry["EndTime"]?.doubleValue, end > start {
                    karaokeLines.append(KaraokeLineDto(syllables: [], startMs: Int(start * 1000),
                                                      endMs: Int(end * 1000), isInterlude: true))
                }
                continue
            }
            guard entry["Type"]?.stringValue == "Vocal",
                  let lead = entry["Lead"] else { continue }

            let lineText: String
            var karaokeSyllables = [KaraokeSyllableDto]()

            if let syllables = lead["Syllables"]?.arrayValue, !syllables.isEmpty {
                karaokeSyllables = SpicyLyricsRepository.syllables(syllables)
                lineText = karaokeSyllables.plainText
                if syllables.contains(where: { ($0["TransliteratedText"]?.stringValue ?? "").isEmpty == false }) {
                    hasRomanized = true
                }
            } else if let text = lead["Text"]?.stringValue {
                lineText = text
            } else {
                continue
            }

            if (lead["TransliteratedText"]?.stringValue ?? "").isEmpty == false { hasRomanized = true }

            let lineStartMs = lead["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? 0
            let lineEndMs   = lead["EndTime"]?.doubleValue.map { Int($0 * 1000) }
                ?? karaokeSyllables.last?.endMs
                ?? lineStartMs

            lines.append(LyricsLineDto(content: lineText.lyricsNoteIfEmpty, offsetMs: lineStartMs))

            let opposite = entry["OppositeAligned"]?.boolValue ?? false
            if let vocal = Self.vocalLine(lead, start: lineStartMs, end: lineEndMs, opposite: opposite) {
                karaokeLines.append(vocal)
            }
            for background in entry["Background"]?.arrayValue ?? [] {
                if let vocal = Self.vocalLine(background, start: lineStartMs, end: lineEndMs,
                                              opposite: opposite, isBackground: true) {
                    karaokeLines.append(vocal)
                }
            }
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        if !karaokeLines.isEmpty {
            let songWriters = root["SongWriters"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let attribution = root["TTMLUploadMetadata"] ?? root["UploadAttribution"]

            let filledKaraokeLines = LyricsUncensorFill.fillKaraoke(
                lines: karaokeLines,
                query: query,
                options: options
            )
            let normalizedKaraokeLines = SpicyLyricsRepository.normalizeMonotonicTiming(filledKaraokeLines)

            KaraokeLyricsStore.shared.set(
                trackId: trackId,
                source: .spicylyrics,
                lyrics: KaraokeLyricsDto(
                    lines: normalizedKaraokeLines,
                    songWriters: songWriters,
                    providerCode: root["source"]?.stringValue,
                    providerName: Self.creditProviderName(root),
                    uploaderName: Self.profileName(attribution?["Uploader"]),
                    uploaderUrl: Self.profileURL(attribution?["Uploader"]),
                    makerName: Self.profileName(attribution?["Maker"]),
                    makerUrl: Self.profileURL(attribution?["Maker"]),
                    uploaderAvatarUrl: attribution?["Uploader"]?["avatar"]?.stringValue,
                    makerAvatarUrl: attribution?["Maker"]?["avatar"]?.stringValue
                )
            )
        }

        return LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: romanization,
            providerCredit: SpicyLyricsRepository.providerCredit(root)
        )
    }

    private static func vocalLine(_ node: SpicyLyricsJSON, start: Int, end: Int,
                                  opposite: Bool, isBackground: Bool = false,
                                  fallbackText: String = "") -> KaraokeLineDto? {
        let startMs = node["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? start
        let endMs = node["EndTime"]?.doubleValue.map { Int($0 * 1000) } ?? end
        var timing = syllables(node["Syllables"]?.arrayValue ?? [])
        if timing.isEmpty {
            let text = node["Text"]?.stringValue ?? node.stringValue ?? fallbackText
            timing = text.split(whereSeparator: { $0.isWhitespace }).map {
                KaraokeSyllableDto(text: String($0), startMs: startMs, endMs: startMs, isPartOfWord: false)
            }
        }
        guard !timing.isEmpty else { return nil }
        return KaraokeLineDto(syllables: timing, startMs: startMs,
                              endMs: max(endMs, timing.map(\.endMs).max() ?? startMs),
                              isOppositeAligned: opposite, isBackground: isBackground)
    }

    // Preserve source onsets, including intentional overlaps; only repair negative durations.
    private static func normalizeMonotonicTiming(_ lines: [KaraokeLineDto]) -> [KaraokeLineDto] {
        var result = lines
        for lineIndex in result.indices {
            for syllableIndex in result[lineIndex].syllables.indices {
                var syllable = result[lineIndex].syllables[syllableIndex]
                if syllable.endMs < syllable.startMs {
                    syllable.endMs = syllable.startMs
                }
                result[lineIndex].syllables[syllableIndex] = syllable
            }
        }
        return result
    }

    // MARK: Line lyrics

    private func parseLineLyrics(_ root: SpicyLyricsJSON, trackId: String, query: LyricsSearchQuery, options: LyricsOptions) -> LyricsDto {
        guard let content = root["Content"]?.arrayValue else { return emptyDto() }

        var lines        = [LyricsLineDto]()
        var karaokeLines = [KaraokeLineDto]()
        let hasRomanized = root["HasTransliterations"]?.boolValue ?? false

        for entry in content {
            if entry["Type"]?.stringValue == "Interlude" {
                if let start = entry["StartTime"]?.doubleValue, let end = entry["EndTime"]?.doubleValue, end > start {
                    karaokeLines.append(KaraokeLineDto(syllables: [], startMs: Int(start * 1000),
                                                      endMs: Int(end * 1000), isInterlude: true))
                }
                continue
            }
            guard entry["Type"]?.stringValue == "Vocal" else { continue }
            let text      = SpicyLyricsRepository.leadText(entry)
            let startTime = entry["Lead"]?["StartTime"]?.doubleValue ?? entry["StartTime"]?.doubleValue
            let endTime   = entry["Lead"]?["EndTime"]?.doubleValue ?? entry["EndTime"]?.doubleValue
            let startMs   = startTime.map { Int($0 * 1000) }
            lines.append(LyricsLineDto(content: text.lyricsNoteIfEmpty, offsetMs: startMs))

            guard let lineStartMs = startMs else { continue }
            let lineEndMs = max(endTime.map { Int($0 * 1000) } ?? lineStartMs, lineStartMs)
            let opposite = entry["OppositeAligned"]?.boolValue ?? false
            if let vocal = Self.vocalLine(entry["Lead"] ?? entry, start: lineStartMs,
                                          end: lineEndMs, opposite: opposite, fallbackText: text) {
                karaokeLines.append(vocal)
            }
            for background in entry["Background"]?.arrayValue ?? [] {
                if let vocal = Self.vocalLine(background, start: lineStartMs, end: lineEndMs,
                                              opposite: opposite, isBackground: true) {
                    karaokeLines.append(vocal)
                }
            }
        }

        let romanization: LyricsRomanizationStatus = hasRomanized
            ? .romanized
            : (lines.map(\.content).canBeRomanized ? .canBeRomanized : .original)

        if !karaokeLines.isEmpty {
            let attribution = root["TTMLUploadMetadata"] ?? root["UploadAttribution"]
            let filledKaraokeLines = LyricsUncensorFill.fillKaraoke(
                lines: karaokeLines,
                query: query,
                options: options
            )

            KaraokeLyricsStore.shared.set(
                trackId: trackId,
                source: .spicylyrics,
                lyrics: KaraokeLyricsDto(
                    lines: SpicyLyricsRepository.normalizeMonotonicTiming(filledKaraokeLines),
                    songWriters: root["SongWriters"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                    providerCode: root["source"]?.stringValue,
                    providerName: Self.creditProviderName(root),
                    uploaderName: Self.profileName(attribution?["Uploader"]),
                    uploaderUrl: Self.profileURL(attribution?["Uploader"]),
                    makerName: Self.profileName(attribution?["Maker"]),
                    makerUrl: Self.profileURL(attribution?["Maker"]),
                    uploaderAvatarUrl: attribution?["Uploader"]?["avatar"]?.stringValue,
                    makerAvatarUrl: attribution?["Maker"]?["avatar"]?.stringValue
                )
            )
        }

        return LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: romanization,
            providerCredit: SpicyLyricsRepository.providerCredit(root)
        )
    }

    // MARK: Static lyrics

    private func parseStaticLyrics(_ root: SpicyLyricsJSON) -> LyricsDto {
        let texts: [String]
        if let rawLines = root["Lines"]?.arrayValue {
            texts = rawLines.compactMap { $0["Text"]?.stringValue }
        } else {
            texts = (root["Content"]?.arrayValue ?? [])
                .filter { $0["Type"]?.stringValue == "Vocal" }
                .map { SpicyLyricsRepository.leadText($0) }
        }
        let lines = texts.map { LyricsLineDto(content: $0.lyricsNoteIfEmpty, offsetMs: nil) }
        let romanization: LyricsRomanizationStatus = lines.map(\.content).canBeRomanized
            ? .canBeRomanized : .original
        return LyricsDto(
            lines: lines,
            timeSynced: false,
            romanization: romanization,
            providerCredit: SpicyLyricsRepository.providerCredit(root)
        )
    }

    private static func leadText(_ entry: SpicyLyricsJSON) -> String {
        if let text = entry["Lead"]?["Text"]?.stringValue ?? entry["Text"]?.stringValue {
            return text
        }
        return syllables(entry["Lead"]?["Syllables"]?.arrayValue ?? []).plainText
    }

    private static func syllables(_ raw: [SpicyLyricsJSON]) -> [KaraokeSyllableDto] {
        raw.compactMap { syllable -> KaraokeSyllableDto? in
            guard let text = syllable["Text"]?.stringValue else { return nil }
            let startMs = syllable["StartTime"]?.doubleValue.map { Int($0 * 1000) } ?? 0
            return KaraokeSyllableDto(
                text: text,
                startMs: startMs,
                endMs: syllable["EndTime"]?.doubleValue.map { Int($0 * 1000) } ?? startMs,
                isPartOfWord: syllable["IsPartOfWord"]?.boolValue ?? false
            )
        }
    }

    private func emptyDto() -> LyricsDto {
        LyricsDto(lines: [], timeSynced: false, romanization: .original)
    }

    // MARK: Attribution

    static let providerName = "Spicy Lyrics"

    private static func creditProviderName(_ root: SpicyLyricsJSON) -> String {
        if root["source"]?.stringValue == "spicy_lyrics" || root["TTMLUploadMetadata"] != nil || root["UploadAttribution"] != nil {
            return "Spicy Lyrics Community"
        }
        return "Apple Music"
    }

    private static func providerCredit(_ root: SpicyLyricsJSON) -> String? {
        guard let code = root["source"]?.stringValue, !code.isEmpty else { return nil }
        var parts = [providerName]
        if code == "spicy_lyrics" {
            let attribution = root["TTMLUploadMetadata"] ?? root["UploadAttribution"]
            if let maker = attribution?["Maker"]?["username"]?.stringValue, !maker.isEmpty {
                parts.append("\("lyrics_made_by".localized) \(maker)")
            }
            if let uploader = attribution?["Uploader"]?["username"]?.stringValue, !uploader.isEmpty {
                parts.append("\("lyrics_uploaded_by".localized) \(uploader)")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let trackId = query.spotifyTrackId
        guard trackId.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil else {
            eeveeLog("[EeveeSpotify][SpicyLyrics] Not a Spotify track id: '%@'", trackId)
            throw LyricsError.noSuchSong
        }

        let start = CFAbsoluteTimeGetCurrent()
        let apiKey = UserDefaults.effectiveSpicyLyricsApiKey
        let (data, httpStatus) = try performQuery(trackId: trackId, apiKey: apiKey)
        var dto = try parseLyricsData(data, httpStatus: httpStatus, trackId: trackId, query: query, options: options, start: start)

        let filledContents = LyricsUncensorFill.fill(
            lines: dto.lines.map(\.content),
            query: query,
            options: options
        )
        for (index, content) in filledContents.enumerated() where index < dto.lines.count {
            dto.lines[index].content = content
        }
        return dto
    }
}
