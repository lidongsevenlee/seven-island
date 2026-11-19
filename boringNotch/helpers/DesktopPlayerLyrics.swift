import Foundation
import QRCCodec
import SQLite3

enum DesktopPlayerLyrics {
    private static let maxFileSize = 512 * 1024

    static func read(_ recording: PlayerLyricsCatalog.Recording, source: PlayerLyricsCatalog.Source) async -> DesktopLyricsCache.Entry? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let reader = Task.detached(priority: .utility) {
            switch source {
            case .qq:
                let database = home.appendingPathComponent("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iRRCache/rrdbcache.sqlite")
                return qqCache(for: recording, database: database)
            case .netease:
                let database = home.appendingPathComponent("Library/Application Support/com.netease.163music/Documents/storage/sqlite_storage.sqlite3")
                let downloads = home.appendingPathComponent("Music/网易云音乐", isDirectory: true)
                return netEaseDownloads(for: recording, database: database, directory: downloads)
            }
        }
        return await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
    }

    static func qqCache(for recording: PlayerLyricsCatalog.Recording, database: URL) -> DesktopLyricsCache.Entry? {
        let selection = recording.songID == nil
            ? "keyId LIKE '%.qrc' OR keyId LIKE '%.lrc'"
            : "keyId IN (?1 || '.qrc', ?1 || '.lrc')"
        let query = """
            SELECT keyId, data FROM Cache
            WHERE type = 3 AND length(data) <= 524288
              AND (\(selection))
            ORDER BY accessTime DESC LIMIT 80
            """
        let candidates: [(id: String, entry: DesktopLyricsCache.Entry)] = rows(database, query, argument: recording.songID) { row in
            guard let name = text(row, 0), let blob = sqlite3_column_blob(row, 1) else { return nil }
            let id = (name as NSString).deletingPathExtension
            guard PlayerLyricsCatalog.Source.numericSongID(id) != nil else { return nil }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(row, 1)))
            guard let value = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data)) as String? else {
                return nil
            }
            let lyric = name.hasSuffix(".qrc") ? decodedQRC(value) : value
            guard let lyric else { return nil }
            if recording.songID == nil {
                guard let title = tag("ti", in: lyric), let artist = tag("ar", in: lyric), let album = tag("al", in: lyric),
                      recording.matchesQQLyricsMetadata(title: title, artists: [artist], album: album) else { return nil }
            }
            guard let entry = (name.hasSuffix(".qrc") ? qqTimeline(lyric) : lrcTimeline(lyric)),
                  (recording.songID != nil && recording.duration <= 0) || fitsPlayback(entry, duration: recording.duration) else { return nil }
            return (id, entry)
        }
        let versions = Dictionary(grouping: candidates, by: \.id)
        guard versions.count == 1, let matches = versions.values.first else { return nil }
        return matches.map(\.entry).max { $0.quality < $1.quality }
    }

    static func netEaseDownloads(for recording: PlayerLyricsCatalog.Recording, database: URL, directory: URL) -> DesktopLyricsCache.Entry? {
        let trackCondition = recording.songID == nil ? "title = ?1" : "tid = ?1 OR id = ?1"
        let query = "SELECT file, title, artist, album, duration FROM track WHERE \(trackCondition) LIMIT 24"
        var files: [URL] = rows(database, query, argument: recording.songID ?? recording.title) { row in
            guard let path = text(row, 0), path.hasPrefix("/"),
                  matchesNetEaseRow(row, recording: recording) else { return nil }
            let duration = sqlite3_column_double(row, 4)
            let expected = recording.duration
            if duration > 0, expected > 0, !PlayerLyricsCatalog.Recording.isPreviewDuration(expected),
               min(abs(duration - expected), abs(duration / 1000 - expected)) > 3 { return nil }
            return URL(fileURLWithPath: path)
        }
        let downloadCondition = recording.songID == nil ? "trackName = ?1" : "id = ?1"
        let downloads = "SELECT newRelativePath, trackName, artistName, albumName FROM offlineTrack WHERE \(downloadCondition) LIMIT 24"
        files += rows(database, downloads, argument: recording.songID ?? recording.title) { row in
            guard let path = text(row, 0), !path.isEmpty,
                  matchesNetEaseRow(row, recording: recording) else { return nil }
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        }
        let lyrics = Set(files.map { $0.standardizedFileURL.deletingPathExtension().appendingPathExtension("lrc") })
        let entries = lyrics.compactMap { url -> DesktopLyricsCache.Entry? in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  size.isRegularFile == true, let count = size.fileSize, count <= maxFileSize,
                  let raw = try? String(contentsOf: url, encoding: .utf8), let entry = lrcTimeline(raw) else { return nil }
            if PlayerLyricsCatalog.Recording.isPreviewDuration(recording.duration), !fitsPlayback(entry, duration: recording.duration) {
                return .init(text: entry.text, lines: [], characterTimings: [])
            }
            return fitsPlayback(entry, duration: recording.duration) ? entry : nil
        }
        return entries.count == 1 ? entries.first : nil
    }

    private static func matchesNetEaseRow(_ row: OpaquePointer, recording: PlayerLyricsCatalog.Recording) -> Bool {
        if recording.songID != nil { return true }
        guard let title = text(row, 1), let artist = text(row, 2), let album = text(row, 3) else { return false }
        return recording.matchesLyricsMetadata(title: title, artist: artist, album: album)
    }

    static func decodedQRC(_ hex: String) -> String? {
        let bytes = Array(hex.utf8)
        guard !bytes.isEmpty, bytes.count <= maxFileSize, bytes.count.isMultiple(of: 16) else { return nil }
        var input: [UInt8] = []
        input.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexDigit(bytes[index]), let low = hexDigit(bytes[index + 1]) else { return nil }
            input.append(high << 4 | low)
        }
        var output = [UInt8](repeating: 0, count: maxFileSize)
        let inputSize = input.count
        let outputSize = output.count
        let length = seven_decode_qrc(&input, inputSize, &output, outputSize)
        guard length > 0, let decoded = String(bytes: output.prefix(length), encoding: .utf8) else { return nil }
        let clean = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        guard let start = clean.range(of: "LyricContent=\"")?.upperBound else { return clean }
        guard let end = clean.range(of: #""\s*/>"#, options: .regularExpression, range: start..<clean.endIndex)?.lowerBound else { return nil }
        return String(clean[start..<end])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "\r")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func qqTimeline(_ lyric: String) -> DesktopLyricsCache.Entry? {
        wordTimeline(lyric, timingsAfterText: true)
    }

    static func netEaseTimeline(_ lyric: String) -> DesktopLyricsCache.Entry? {
        wordTimeline(lyric, timingsAfterText: false)
    }

    private static let wordTiming = try! NSRegularExpression(pattern: #"\((\d+),(\d+)(?:,\d+)?\)"#)

    private static func wordTimeline(_ lyric: String, timingsAfterText: Bool) -> DesktopLyricsCache.Entry? {
        var result: [(DesktopLyricsCache.Entry.Line, [LyricsDisplayText.CharacterTiming])] = []
        for row in lyric.split(whereSeparator: \.isNewline) {
            guard row.first == "[", let close = row.firstIndex(of: "]"),
                  let lineStart = Double(row[row.index(after: row.startIndex)..<close].split(separator: ",").first ?? ""),
                  lineStart.isFinite, lineStart >= 0 else { continue }
            let content = String(row[row.index(after: close)...])
            let matches = wordTiming.matches(in: content, range: NSRange(content.startIndex..., in: content))
            var words = ""
            var timings: [LyricsDisplayText.CharacterTiming] = []
            var preceding = content.startIndex
            for (index, match) in matches.enumerated() {
                guard let span = Range(match.range, in: content),
                      let startRange = Range(match.range(at: 1), in: content),
                      let durationRange = Range(match.range(at: 2), in: content),
                      let start = Double(content[startRange]), let duration = Double(content[durationRange]),
                      (start + duration).isFinite else { continue }
                let word: Substring
                if timingsAfterText {
                    word = content[preceding..<span.lowerBound]
                    preceding = span.upperBound
                } else {
                    let next = matches.dropFirst(index + 1).first.flatMap { Range($0.range, in: content)?.lowerBound } ?? content.endIndex
                    word = content[span.upperBound..<next]
                }
                words += word
                timings.append(contentsOf: repeatElement(.init(start: start / 1000, end: (start + duration) / 1000), count: word.count))
            }
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append((.init(time: lineStart / 1000, text: words), timings.count == words.count ? timings : []))
        }
        result.sort { $0.0.time < $1.0.time }
        guard !result.isEmpty else { return nil }
        let lines = result.map(\.0)
        return .init(text: lines.map(\.text).joined(separator: "\n"), lines: lines, characterTimings: result.map(\.1))
    }

    static func lrcTimeline(_ lyric: String) -> DesktopLyricsCache.Entry? {
        let parsed = LyricsDisplayText.parseSyncedLyrics(lyric.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")))
        let lines = parsed.lines.map { DesktopLyricsCache.Entry.Line(time: $0.time, text: $0.text) }
        guard !lines.isEmpty else { return nil }
        return .init(text: lines.map(\.text).joined(separator: "\n"), lines: lines,
                     characterTimings: parsed.characterTimes.map { $0.map { .init(start: $0) } })
    }

    private static func fitsPlayback(_ entry: DesktopLyricsCache.Entry, duration: Double) -> Bool {
        duration.isFinite && duration > 0 && (entry.lines.last?.time ?? 0) <= duration + 3
    }

    private static func tag(_ name: String, in lyric: String) -> String? {
        let prefix = "[\(name):"
        return lyric.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) && $0.hasSuffix("]") })
            .map { String($0.dropFirst(prefix.count).dropLast()) }
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func rows<T>(_ url: URL, _ query: String, argument: String? = nil, read: (OpaquePointer) -> T?) -> [T] {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard status == SQLITE_OK, let database else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        if let argument {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, argument, -1, transient) == SQLITE_OK else { return [] }
        }
        var results: [T] = []
        while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
            if let value = read(statement) { results.append(value) }
        }
        return results
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }
}
