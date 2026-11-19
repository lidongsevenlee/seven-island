import Foundation
import OSLog
import SQLite3

enum AppleMusicCachedLyrics {
    typealias Timeline = (lines: [LyricsDisplayText.SyncedLine], characterTimings: [[LyricsDisplayText.CharacterTiming]])

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/com.apple.Music", isDirectory: true)

    private static let logger = Logger(subsystem: "com.local.seven-island", category: "AppleMusicLyrics")
    private static let maximumPayloadSize = 4 * 1024 * 1024

    static func makeBookmark(for url: URL) throws -> Data {
        guard url.standardizedFileURL == directory.standardizedFileURL else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
    }

    static func read(
        bookmark: Data,
        title: String,
        artist: String,
        album: String,
        duration: Double
    ) async -> Timeline? {
        guard !title.isEmpty, !artist.isEmpty, !album.isEmpty, duration.isFinite, duration > 0 else {
            return nil
        }
        let track = Track(title: title, artist: artist, album: album, duration: duration)
        let task = Task.detached(priority: .utility) {
            read(bookmark: bookmark, matching: track)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func read(bookmark: Data, matching track: Track) -> Timeline? {
        var stale = false
        guard let folder = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale, folder.standardizedFileURL == directory.standardizedFileURL,
        folder.startAccessingSecurityScopedResource() else { return nil }
        defer { folder.stopAccessingSecurityScopedResource() }

        let path = folder.appendingPathComponent("Cache.db").path
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(database, 100)

        let sql = """
            SELECT receiver.isDataOnFS, receiver.receiver_data
              FROM cfurl_cache_response AS response
              JOIN cfurl_cache_receiver_data AS receiver ON receiver.entry_ID = response.entry_ID
             WHERE response.request_key LIKE 'https://amp-api.music.apple.com/v1/catalog/%/songs%'
               AND response.request_key LIKE '%syllable-lyrics%'
             ORDER BY response.entry_ID DESC
             LIMIT 100
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        let deadline = ContinuousClock.now + .seconds(1)
        var lineOnly: Timeline?
        while !Task.isCancelled, ContinuousClock.now < deadline, sqlite3_step(statement) == SQLITE_ROW {
            guard let payload = payload(from: statement, in: folder),
                  let timeline = timeline(in: payload, matching: track) else { continue }
            let characterTimedLines = timeline.characterTimings.filter { !$0.isEmpty }.count
            if characterTimedLines > 0 {
                logger.debug("Cached Apple Music TTML matched \(timeline.lines.count) lines, \(characterTimedLines) with character timing")
                return timeline
            }
            if lineOnly == nil { lineOnly = timeline }
        }
        if let lineOnly {
            logger.debug("Cached Apple Music TTML matched \(lineOnly.lines.count) lines with line timing")
        }
        return lineOnly
    }

    private static func payload(from statement: OpaquePointer?, in folder: URL) -> Data? {
        let size = Int(sqlite3_column_bytes(statement, 1))
        guard size > 0, size <= maximumPayloadSize,
              let bytes = sqlite3_column_blob(statement, 1) else { return nil }
        let data = Data(bytes: bytes, count: size)
        guard sqlite3_column_int(statement, 0) == 1 else { return data }
        guard let filename = String(data: data, encoding: .utf8), UUID(uuidString: filename) != nil else {
            return nil
        }
        let file = folder.appendingPathComponent("fsCachedData", isDirectory: true).appendingPathComponent(filename)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let content = try? handle.read(upToCount: maximumPayloadSize + 1),
              content.count <= maximumPayloadSize else { return nil }
        return content
    }

    private struct Track: Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: Double

        func matches(_ metadata: [String: Any]) -> Bool {
            guard let name = metadata["name"] as? String,
                  let artistName = metadata["artistName"] as? String,
                  let albumName = metadata["albumName"] as? String,
                  let milliseconds = metadata["durationInMillis"] as? Double,
                  abs(milliseconds / 1000 - duration) < 1 else { return false }
            return Self.matches(name, title) && Self.matches(artistName, artist) && Self.matches(albumName, album)
        }

        private static func matches(_ lhs: String, _ rhs: String) -> Bool {
            lhs.trimmingCharacters(in: .whitespacesAndNewlines).compare(
                rhs.trimmingCharacters(in: .whitespacesAndNewlines),
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            ) == .orderedSame
        }
    }

    private static func timeline(in payload: Data, matching track: Track) -> Timeline? {
        guard let response = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let songs = response["data"] as? [[String: Any]] else { return nil }
        for song in songs {
            guard let metadata = song["attributes"] as? [String: Any], track.matches(metadata),
                  let relationships = song["relationships"] as? [String: Any],
                  let lyrics = relationships["syllable-lyrics"] as? [String: Any],
                  let resources = lyrics["data"] as? [[String: Any]] else { continue }
            for resource in resources {
                guard let attributes = resource["attributes"] as? [String: Any],
                      let ttml = attributes["ttmlLocalizations"] as? String,
                      let timeline = parseTTML(ttml, duration: track.duration) else { continue }
                return timeline
            }
        }
        return nil
    }

    static func parseTTML(_ ttml: String, duration: Double) -> Timeline? {
        let reader = TTMLReader()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse(), reader.isTTML, reader.timedLines.count > 1,
              reader.timedLines.allSatisfy({ $0.line.time < duration }) else { return nil }

        var timeline: [TTMLReader.TimedLine] = []
        for entry in reader.timedLines.sorted(by: { $0.line.time < $1.line.time }) {
            if let last = timeline.last, last.line.time == entry.line.time {
                let index = timeline.count - 1
                if last.line.text != entry.line.text {
                    timeline[index].line.text += " / " + entry.line.text
                    timeline[index].timings = []
                } else if last.timings.isEmpty {
                    timeline[index].timings = entry.timings
                }
            } else {
                timeline.append(entry)
            }
        }
        guard timeline.count > 1 else { return nil }
        return (timeline.map(\.line), timeline.map(\.timings))
    }

    private final class TTMLReader: NSObject, XMLParserDelegate {
        typealias TimedLine = (line: LyricsDisplayText.SyncedLine, timings: [LyricsDisplayText.CharacterTiming])

        private struct Segment {
            var text: String
            let interval: Range<Double>?
        }

        private struct Line {
            let start: Double
            var segments: [Segment] = []
        }

        private(set) var timedLines: [TimedLine] = []
        private(set) var isTTML = false
        private var line: Line?
        private var spanTimings: [Range<Double>?] = []

        func parser(
            _ parser: XMLParser,
            didStartElement element: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            if element == "tt", namespaceURI == "http://www.w3.org/ns/ttml" {
                isTTML = true
            } else if element == "p", let begin = attributes["begin"], let time = Self.seconds(begin) {
                line = Line(start: time)
            } else if element == "span", line != nil {
                if let begin = attributes["begin"].flatMap(Self.seconds),
                   let end = attributes["end"].flatMap(Self.seconds), end > begin {
                    spanTimings.append(begin..<end)
                } else {
                    spanTimings.append(spanTimings.last ?? nil)
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard var line, !string.isEmpty else { return }
            let interval = spanTimings.last ?? nil
            if let last = line.segments.last, last.interval == interval {
                line.segments[line.segments.count - 1].text.append(string)
            } else {
                line.segments.append(Segment(text: string, interval: interval))
            }
            self.line = line
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "span", !spanTimings.isEmpty {
                spanTimings.removeLast()
            }
            guard element == "p", let line else { return }
            self.line = nil
            spanTimings.removeAll(keepingCapacity: true)
            let fullText = line.segments.map(\.text).joined()
            let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let timings = characterTimings(for: line, fullText: fullText, trimmedText: text)
            timedLines.append(((line.start, text), timings))
        }

        private func characterTimings(for line: Line, fullText: String, trimmedText: String) -> [LyricsDisplayText.CharacterTiming] {
            guard line.segments.contains(where: { $0.interval != nil && $0.text.contains(where: { !$0.isWhitespace }) }) else {
                return []
            }
            var previousEnd = line.start
            var timings: [LyricsDisplayText.CharacterTiming] = []
            for segment in line.segments {
                let count = segment.text.count
                let start = segment.interval?.lowerBound ?? previousEnd
                let end = segment.interval?.upperBound ?? start
                let step = (end - start) / Double(count)
                for index in 0..<count {
                    timings.append(.init(
                        start: start + step * Double(index),
                        end: index == count - 1 ? end : start + step * Double(index + 1)
                    ))
                }
                previousEnd = end
            }
            let leadingWhitespace = fullText.prefix(while: \.isWhitespace).count
            let visible = timings.dropFirst(leadingWhitespace).prefix(trimmedText.count)
            guard timings.count == fullText.count, visible.count == trimmedText.count,
                  zip(visible, visible.dropFirst()).allSatisfy({ $0.start <= $1.start }) else { return [] }
            return Array(visible)
        }

        private static func seconds(_ time: String) -> Double? {
            let fields = time.split(separator: ":", omittingEmptySubsequences: false)
            let numbers = fields.compactMap { Double($0) }
            guard (1...3).contains(fields.count), numbers.count == fields.count,
                  numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  let last = numbers.last, fields.count == 1 || last < 60 else { return nil }
            let seconds = numbers.reduce(0) { $0 * 60 + $1 }
            return seconds.isFinite ? seconds : nil
        }
    }
}
