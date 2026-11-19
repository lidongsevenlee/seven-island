import Foundation

enum PlayerLyricsCatalog {
    enum Source {
        case netease
        case qq

        init?(bundleIdentifier: String?) {
            guard let bundleIdentifier else { return nil }
            let playback = PlaybackState.idle(bundleIdentifier: bundleIdentifier)
            if playback.isFrom(MediaControllerType.neteaseMusic.systemPlayerBundleIdentifier) {
                self = .netease
            } else if playback.isFrom(MediaControllerType.qqMusic.systemPlayerBundleIdentifier) {
                self = .qq
            } else {
                return nil
            }
        }

        var alternate: Source { self == .netease ? .qq : .netease }

        static func numericSongID(_ identifier: String?) -> String? {
            guard let identifier, !identifier.isEmpty,
                  identifier.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(identifier), number > 0 else { return nil }
            return String(number)
        }
    }

    struct Recording {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        var songID: String? = nil

        var searchTerm: String { "\(title) \(artist)" }

        var canMatchLocalLyrics: Bool {
            songID != nil || (duration.isFinite && duration > 0 &&
                [title, artist, album].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            )
        }

        static func isPreviewDuration(_ duration: Double) -> Bool {
            [30.0, 35.0].contains { abs(duration - $0) <= 1 }
        }

        func matchesNetEasePreview(_ song: Song) -> Bool {
            guard Self.isPreviewDuration(duration), !album.isEmpty, song.duration > 60 else { return false }
            let albumRecording = Recording(title: title, artist: artist, album: album, duration: 0)
            return albumRecording.matches(title: song.title, artists: song.artists, album: song.album, duration: song.duration)
        }

        func matchesLyricsMetadata(title: String, artist: String, album: String) -> Bool {
            guard !self.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let albumRecording = Recording(title: self.title, artist: self.artist, album: self.album, duration: 0)
            return albumRecording.matches(title: title, artists: [artist], album: album, duration: 0)
        }

        func matchesQQLyricsMetadata(title: String, artists: [String], album: String) -> Bool {
            let expectedAlbum = PlayerLyricsCatalog.normalized(self.album)
            guard !expectedAlbum.isEmpty, expectedAlbum == PlayerLyricsCatalog.normalized(album) else { return false }
            let expectedTitle = PlayerLyricsCatalog.normalized(self.title)
            let candidateTitle = PlayerLyricsCatalog.normalized(title)
            guard !expectedTitle.isEmpty,
                  expectedTitle == candidateTitle ||
                    expectedTitle == PlayerLyricsCatalog.qqTitleWithoutTribute(title) ||
                    candidateTitle == PlayerLyricsCatalog.qqTitleWithoutTribute(self.title) else { return false }
            return artistCreditsMatch(artists, allowMissingCredits: true)
        }

        func matches(title: String, artists: [String], album: String, duration: Double) -> Bool {
            let wantedTitle = PlayerLyricsCatalog.normalized(self.title)
            guard !wantedTitle.isEmpty, wantedTitle == PlayerLyricsCatalog.normalized(title) else { return false }
            if self.duration.isFinite, self.duration > 0 {
                guard duration.isFinite, duration > 0, abs(self.duration - duration) <= 3 else { return false }
            } else if !self.album.isEmpty {
                guard PlayerLyricsCatalog.normalized(self.album) == PlayerLyricsCatalog.normalized(album) else { return false }
            }

            return artistCreditsMatch(artists)
        }

        private func artistCreditsMatch(_ artists: [String], allowMissingCredits: Bool = false) -> Bool {
            let separators = CharacterSet(charactersIn: "/、,，&")
            let wantedArtists = artist.components(separatedBy: separators).map(PlayerLyricsCatalog.normalized).filter { !$0.isEmpty }
            let credits = artists.flatMap { $0.components(separatedBy: separators) }.map(PlayerLyricsCatalog.normalized).filter { !$0.isEmpty }
            guard !wantedArtists.isEmpty, !credits.isEmpty else { return false }
            if PlayerLyricsCatalog.normalized(artist) == PlayerLyricsCatalog.normalized(artists.joined()) { return true }
            return (allowMissingCredits || wantedArtists.count == credits.count) && wantedArtists.allSatisfy { name in
                credits.contains { PlayerLyricsCatalog.artistMatches(name, credit: $0) }
            }
        }
    }

    struct Song {
        let id: String
        let title: String
        let artists: [String]
        let album: String
        let duration: Double
        var qqSongNumber: Int? = nil
    }

    struct Lyric {
        let lines: String
        let words: String?
    }

    static func search(_ recording: Recording, in source: Source, allowPreview: Bool = false,
                       allowQQAliases: Bool = false) async -> [Song] {
        let songs = await catalogSearch(recording.searchTerm, in: source)
        let matches = ranked(songs, for: recording, allowQQAliases: allowQQAliases)
        if matches.isEmpty, source == .qq, allowQQAliases,
           qqTitleWithoutTribute(recording.album) == normalized(recording.title) {
            let albumResults = await catalogSearch(recording.album, in: source)
            return ranked(albumResults, for: recording, allowQQAliases: true)
        }
        guard matches.isEmpty, source == .netease, allowPreview else { return matches }
        let previews = songs.filter(recording.matchesNetEasePreview)
        return previews.count == 1 ? previews : []
    }

    private static func catalogSearch(_ query: String, in source: Source) async -> [Song] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var request: URLRequest
        switch source {
        case .netease:
            request = URLRequest(url: URL(string: "https://music.163.com/api/search/get/web")!, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            var form = URLComponents()
            form.queryItems = [
                .init(name: "s", value: query),
                .init(name: "type", value: "1"),
                .init(name: "limit", value: "10"),
                .init(name: "offset", value: "0"),
            ]
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        case .qq:
            request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "req": [
                    "module": "music.search.SearchCgiService",
                    "method": "DoSearchForQQMusicDesktop",
                    "param": ["query": query, "num_per_page": 10, "page_num": 1, "search_type": 0],
                ],
            ])
        }

        guard let response = await json(for: request) else { return [] }
        let records: [[String: Any]]
        switch source {
        case .netease:
            records = (response["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        case .qq:
            let endpoint = response["req"] as? [String: Any]
            let payload = endpoint?["data"] as? [String: Any]
            let body = payload?["body"] as? [String: Any]
            records = (body?["song"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        }
        return records.compactMap { catalogSong($0, source: source) }
    }

    static func lyric(for song: Song, in source: Source) async -> Lyric? {
        if source == .netease {
            return await netEaseLyric(id: song.id)
        }
        var endpoint = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        endpoint.queryItems = [
            .init(name: "songmid", value: song.id), .init(name: "format", value: "json"), .init(name: "nobase64", value: "1"),
        ]
        guard let url = endpoint.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let response = await json(for: request), let lyric = response["lyric"] as? String, !lyric.isEmpty else { return nil }
        if let decoded = Data(base64Encoded: lyric), let text = String(data: decoded, encoding: .utf8) {
            return Lyric(lines: text, words: nil)
        }
        return Lyric(lines: lyric, words: nil)
    }

    static func netEaseLyric(id: String) async -> Lyric? {
        for path in ["/api/song/lyric/v1", "/api/song/lyric"] {
            guard !Task.isCancelled else { return nil }
            if let lyrics = await netEaseLyric(id: id, path: path) { return lyrics }
        }
        return nil
    }

    private static func netEaseLyric(id: String, path: String) async -> Lyric? {
        var endpoint = URLComponents(string: "https://music.163.com")!
        endpoint.path = path
        endpoint.queryItems = [.init(name: "id", value: id)] + ["lv", "tv", "rv", "yv"].map { .init(name: $0, value: "-1") }
        guard let url = endpoint.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let response = await json(for: request), response["nolyric"] as? Bool != true else { return nil }
        let lines = (response["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        let words = (response["yrc"] as? [String: Any])?["lyric"] as? String
        return lines.isEmpty && (words?.isEmpty ?? true) ? nil : Lyric(lines: lines, words: words)
    }

    static func qqWordLyrics(for song: Song) async -> DesktopLyricsCache.Entry? {
        guard let songID = song.qqSongNumber else { return nil }
        return await qqWordLyrics(id: songID, mid: song.id)
    }

    static func qqWordLyrics(id: Int, mid: String? = nil) async -> DesktopLyricsCache.Entry? {
        var parameters: [String: Any] = [
            "songID": id,
            "qrc": 1, "qrc_t": 0, "lrc_t": 0, "trans": 0, "roma": 0, "crypt": 1, "type": 0, "ct": 19, "cv": 1859,
        ]
        if let mid { parameters["songMID"] = mid }
        var request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "comm": ["ct": 19, "cv": 1859, "format": "json"],
            "lyric": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo", "param": parameters],
        ])
        guard let response = await json(for: request), let result = response["lyric"] as? [String: Any],
              let data = result["data"] as? [String: Any], let payload = data["lyric"] as? String,
              let lyric = DesktopPlayerLyrics.decodedQRC(payload) else { return nil }
        return DesktopPlayerLyrics.qqTimeline(lyric)
    }

    static func qqProxySongs(from response: [String: Any], for recording: Recording) -> [Song] {
        let payload = response["data"]
        let entries = (payload as? [String: Any])?["items"] as? [[String: Any]] ?? payload as? [[String: Any]] ?? []
        let songs = entries.compactMap { entry -> Song? in
            guard let id = entry["mid"] as? String, let title = entry["name"] as? String else { return nil }
            return Song(id: id, title: title, artists: entry["singer"] as? [String] ?? [],
                        album: entry["album"] as? String ?? "", duration: number(entry["duration"]))
        }
        return ranked(songs, for: recording)
    }

    private static func catalogSong(_ entry: [String: Any], source: Source) -> Song? {
        let album = entry["album"] as? [String: Any]
        switch source {
        case .netease:
            guard let id = entry["id"] as? NSNumber, let title = entry["name"] as? String else { return nil }
            let artists = (entry["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return Song(id: id.stringValue, title: title, artists: artists,
                        album: album?["name"] as? String ?? "", duration: number(entry["duration"]) / 1000)
        case .qq:
            guard let id = entry["mid"] as? String, let title = entry["title"] as? String else { return nil }
            let artists = (entry["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return Song(id: id, title: title, artists: artists,
                        album: album?["name"] as? String ?? "", duration: number(entry["interval"]),
                        qqSongNumber: (entry["id"] as? NSNumber)?.intValue)
        }
    }

    private static func ranked(_ songs: [Song], for recording: Recording, allowQQAliases: Bool = false) -> [Song] {
        let wantedAlbum = normalized(recording.album)
        let exact = songs.filter {
            recording.matches(title: $0.title, artists: $0.artists, album: $0.album, duration: $0.duration)
        }
        if allowQQAliases, !exact.contains(where: { normalized($0.album) == wantedAlbum }) {
            let aliases = songs.filter {
                recording.duration > 0 && $0.duration > 0 && abs(recording.duration - $0.duration) <= 3 &&
                    recording.matchesQQLyricsMetadata(title: $0.title, artists: $0.artists, album: $0.album)
            }
            if Set(aliases.map(\.id)).count == 1, let alias = aliases.first { return [alias] }
            if !aliases.isEmpty { return [] }
        }
        return exact.sorted {
            let leftAlbum = !wantedAlbum.isEmpty && normalized($0.album) == wantedAlbum
            let rightAlbum = !wantedAlbum.isEmpty && normalized($1.album) == wantedAlbum
            if leftAlbum != rightAlbum { return leftAlbum }
            return abs($0.duration - recording.duration) < abs($1.duration - recording.duration)
        }
    }

    private static func qqTitleWithoutTribute(_ text: String) -> String? {
        let pattern = #"(?i)\s*[(（]\s*(?:tribute\s+to\s+[^()（）]+|cover(?:\s+(?:of|by)\s+[^()（）]+)?|翻唱(?:版)?)\s*[)）]\s*$"#
        guard let suffix = text.range(of: pattern, options: .regularExpression) else { return nil }
        return normalized(String(text[..<suffix.lowerBound]))
    }

    private static func artistMatches(_ name: String, credit: String) -> Bool {
        if name == credit { return true }
        let shorter = name.count < credit.count ? name : credit
        let longer = name.count < credit.count ? credit : name
        guard longer.hasPrefix(shorter), shorter.range(of: #"^\p{Han}{2,}$"#, options: .regularExpression) != nil else { return false }
        return longer.dropFirst(shorter.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) ?? 0
    }

    private static func json(for request: URLRequest) async -> [String: Any]? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !Task.isCancelled else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
