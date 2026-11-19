import Foundation

typealias LyricsHTTPRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)

func normalizedLyricsQuery(_ string: String) -> String {
    string
        .folding(options: .diacriticInsensitive, locale: .current)
        .replacingOccurrences(of: "\u{FFFD}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}


struct WebLyrics: Sendable {
    let request: LyricsHTTPRequest

    enum Reference {
        case timeline([LyricsDisplayText.SyncedLine])
        case lyrics(String)
        case recording
        case desktopRecording(PlayerLyricsCatalog.Recording)
    }

    private struct Candidate {
        let plain: String
        let synced: String
        let parsed: (lines: [LyricsDisplayText.SyncedLine], characterTimes: [[Double]])
        /// Duration reported by LRCLIB for this entry (seconds). Used to rank candidates
        /// when multiple results match the same title/artist — the entry whose duration
        /// is closest to the actual track duration wins.
        let lrclibDuration: Double
        let recording: (title: String, artist: String, album: String)?

        init(plain: String, synced: String, parsed: (lines: [LyricsDisplayText.SyncedLine], characterTimes: [[Double]]), lrclibDuration: Double = 0,
             recording: (title: String, artist: String, album: String)? = nil) {
            self.plain = plain
            self.synced = synced
            self.parsed = parsed
            self.lrclibDuration = lrclibDuration
            self.recording = recording
        }

        var hasText: Bool {
            !plain.isEmpty || !synced.isEmpty || !parsed.lines.isEmpty
        }

        var hasCharacterTiming: Bool {
            parsed.characterTimes.contains { !$0.isEmpty }
        }

        var displayLyrics: String {
            if !plain.isEmpty { return plain }
            if !synced.isEmpty { return synced }
            return parsed.lines.map(\.text).joined(separator: "\n")
        }

        var entry: DesktopLyricsCache.Entry {
            .init(text: displayLyrics, lines: parsed.lines.map { .init(time: $0.time, text: $0.text) },
                  characterTimings: hasCharacterTiming ? parsed.characterTimes.map { $0.map { .init(start: $0) } } : [])
        }
    }

    private func lyricTitleQueries(from title: String) -> [String] {
        let normalized = normalizedLyricsQuery(title)
        let withoutParentheses = normalized
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFeaturing = withoutParentheses
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return [normalized, withoutParentheses, withoutFeaturing].reduce(into: [String]()) { result, query in
            guard !query.isEmpty, !result.contains(query) else { return }
            result.append(query)
        }
    }

    private func lyricSearchURL(title: String, artist: String) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        return components?.url
    }

    /// LRCLIB /api/get — exact lookup with duration for tiebreaking.
    /// Returns nil on 404 or network error.
    private func lyricExactURL(title: String, artist: String, album: String, duration: Double) -> URL? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let seconds = Int(exactly: duration.rounded()), seconds > 0 {
            items.append(URLQueryItem(name: "duration", value: String(seconds)))
        }
        components?.queryItems = items
        return components?.url
    }

    func find(_ recording: PlayerLyricsCatalog.Recording, matching reference: Reference? = nil) async -> DesktopLyricsCache.Entry? {
        guard !Task.isCancelled else { return nil }
        let (title, artist, album, duration) = (recording.title, recording.artist, recording.album, recording.duration)
        let cleanArtist = normalizedLyricsQuery(artist)
        let cleanAlbum = normalizedLyricsQuery(album)
        let cleanTitle = normalizedLyricsQuery(title)
        var fallbackCandidate: Candidate?

        func matchesReference(_ candidate: Candidate) -> Bool {
            switch reference {
            case .timeline(let lines):
                return candidate.hasCharacterTiming && LyricsDisplayText.matchesPlaybackTimeline(candidate.parsed.lines, reference: lines)
            case .lyrics(let text):
                guard let end = candidate.parsed.lines.last?.time, duration <= 0 || end < duration else { return false }
                return LyricsDisplayText.matchesLyricText(candidate.parsed.lines, reference: text)
            case .recording:
                guard let recording = candidate.recording, duration.isFinite, duration > 0,
                      !album.isEmpty, abs(candidate.lrclibDuration - duration) <= 2 else { return false }
                return normalizedLyricsQuery(recording.title).caseInsensitiveCompare(cleanTitle) == .orderedSame &&
                    normalizedLyricsQuery(recording.artist).caseInsensitiveCompare(cleanArtist) == .orderedSame &&
                    normalizedLyricsQuery(recording.album).caseInsensitiveCompare(cleanAlbum) == .orderedSame
            case .desktopRecording(let target):
                guard let recording = candidate.recording else { return false }
                return target.matches(title: recording.title, artists: [recording.artist], album: recording.album,
                                      duration: candidate.lrclibDuration)
            case nil:
                return true
            }
        }

        // ── Step 1: LRCLIB /api/get — exact match (title + artist + album + duration) ──
        // This endpoint returns a single result and matches on duration when provided,
        // giving accurate version selection without needing to sort a search result list.
        if let exactURL = lyricExactURL(title: cleanTitle, artist: cleanArtist, album: cleanAlbum, duration: duration) {
            if let candidate = try? await fetchLrclibSingle(url: exactURL), candidate.hasText, matchesReference(candidate) {
                guard !Task.isCancelled else { return nil }
                return candidate.entry
            }
        }

        // ── Step 2: LRCLIB /api/search — ranked by duration proximity ──
        // Falls back here when the exact endpoint returns 404 (album name mismatch,
        // simplified/traditional Chinese differences, etc.).
        for titleQuery in lyricTitleQueries(from: title) {
            guard !Task.isCancelled else { return nil }
            guard let url = lyricSearchURL(title: titleQuery, artist: cleanArtist) else { continue }
            do {
                let (data, response) = try await request(URLRequest(url: url))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }

                var candidates = jsonArray.compactMap(lrclibCandidate).filter(matchesReference)

                // Sort by duration proximity when we have actual track duration.
                // Candidates within 2 s are considered equally good; outside that,
                // prefer closer ones to avoid picking live/demo/remix variants.
                if duration > 0 {
                    candidates.sort {
                        let da = abs($0.lrclibDuration - duration)
                        let db = abs($1.lrclibDuration - duration)
                        // Prefer character-timed entries when both are close enough.
                        if max(da, db) < 2 { return $0.hasCharacterTiming && !$1.hasCharacterTiming }
                        return da < db
                    }
                }

                if let enhanced = candidates.first(where: \.hasCharacterTiming) {
                    guard !Task.isCancelled else { return nil }
                    return enhanced.entry
                }

                if fallbackCandidate == nil {
                    fallbackCandidate = candidates.first
                }
            } catch {
                continue
            }
        }

        guard !Task.isCancelled else { return nil }
        let allowsQQMusic = switch reference {
        case .recording, .desktopRecording: false
        default: true
        }
        if allowsQQMusic, let enhanced = await fetchEnhancedLyricsFromQQMusic(recording),
           matchesReference(enhanced) {
            guard !Task.isCancelled else { return nil }
            return enhanced.entry
        }

        guard !Task.isCancelled else { return nil }
        if let fallbackCandidate {
            return fallbackCandidate.entry
        }

        return nil
    }

    /// Fetch a single LRCLIB result from the given URL (used for /api/get exact endpoint).
    private func fetchLrclibSingle(url: URL) async throws -> Candidate? {
        let (data, response) = try await request(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lrclibCandidate(result)
    }

    private func lrclibCandidate(_ result: [String: Any]) -> Candidate? {
        let plain = (result["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let synced = (result["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsed = synced.isEmpty ? (lines: [], characterTimes: []) : LyricsDisplayText.parseSyncedLyrics(synced)
        let lrclibDuration = result["duration"] as? Double ?? 0
        let recording = (title: result["trackName"] as? String ?? "", artist: result["artistName"] as? String ?? "",
                         album: result["albumName"] as? String ?? "")
        let candidate = Candidate(plain: plain, synced: synced, parsed: parsed, lrclibDuration: lrclibDuration, recording: recording)
        return candidate.hasText ? candidate : nil
    }

    private func fetchEnhancedLyricsFromQQMusic(_ recording: PlayerLyricsCatalog.Recording) async -> Candidate? {
        let query = [normalizedLyricsQuery(recording.title), normalizedLyricsQuery(recording.artist)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty,
              var components = URLComponents(string: "https://oiapi.net/api/QQMusicLyric") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "keyword", value: query),
            URLQueryItem(name: "format", value: "qrc"),
            URLQueryItem(name: "type", value: "json")
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await request(URLRequest(url: url))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            if let candidate = Self.qrcCandidate(from: json) {
                return candidate
            }

            for song in PlayerLyricsCatalog.qqProxySongs(from: json, for: recording).prefix(3) {
                if let candidate = await fetchQQMusicLyricByID(song.id) {
                    return candidate
                }
            }

            return nil
        } catch {
            return nil
        }
    }

    func qqLyrics(forSongID id: String) async -> DesktopLyricsCache.Entry? {
        await fetchQQMusicLyricByID(id)?.entry
    }

    private func fetchQQMusicLyricByID(_ id: String) async -> Candidate? {
        guard var components = URLComponents(string: "https://oiapi.net/api/QQMusicLyric") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "format", value: "qrc"),
            URLQueryItem(name: "type", value: "json")
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await request(URLRequest(url: url, timeoutInterval: 5))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return Self.qrcCandidate(from: json)
        } catch {
            return nil
        }
    }

    private static func qrcCandidate(from json: [String: Any]) -> Candidate? {
        if let lyric = lyricPayloadText(from: json) {
            let parsed = LyricsDisplayText.parseQQMusicQRC(lyric)
            let candidate = Candidate(plain: "", synced: lyric, parsed: parsed)
            return candidate.hasCharacterTiming ? candidate : nil
        }

        if let data = json["data"] as? [String: Any],
           let lyric = lyricPayloadText(from: data) {
            let parsed = LyricsDisplayText.parseQQMusicQRC(lyric)
            let candidate = Candidate(plain: "", synced: lyric, parsed: parsed)
            return candidate.hasCharacterTiming ? candidate : nil
        }

        return nil
    }

    private static func lyricPayloadText(from dictionary: [String: Any]) -> String? {
        let keys = ["conteng", "content", "lyric", "lyrics", "qrc", "lrc"]
        for key in keys {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let base64 = dictionary["base64"] as? String,
           let data = Data(base64Encoded: base64),
           let decoded = String(data: data, encoding: .utf8),
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}
