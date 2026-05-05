//
//  LyricsDisplayText.swift
//  boringNotch
//

import Foundation

enum LyricsDisplayText {
    struct Line: Equatable {
        let text: String
        let isCurrent: Bool
    }

    typealias SyncedLine = (time: Double, text: String)

    static func parseSyncedLyrics(_ lrc: String) -> (lines: [SyncedLine], characterTimes: [[Double]]) {
        var parsedLines: [SyncedLine] = []
        var parsedCharacterTimes: [[Double]] = []

        lrc.split(whereSeparator: \.isNewline).forEach { lineSub in
            let line = String(lineSub)
            guard let lineMatch = firstTimestampMatch(in: line, opening: "[", closing: "]"),
                  let lineTime = timestampValue(from: lineMatch.value) else {
                return
            }

            let lyricStart = line.index(line.startIndex, offsetBy: lineMatch.endOffset)
            let lyricBody = String(line[lyricStart...]).trimmingCharacters(in: .whitespaces)
            let inlineSegments = inlineTimedSegments(from: lyricBody)
            let text: String
            let times: [Double]

            if inlineSegments.isEmpty {
                text = lyricBody
                times = []
            } else {
                text = inlineSegments.map(\.text).joined()
                times = characterTimes(from: inlineSegments)
            }

            if !text.isEmpty {
                parsedLines.append((lineTime, text))
                parsedCharacterTimes.append(times.count == text.count ? times : [])
            }
        }

        let combined = zip(parsedLines, parsedCharacterTimes)
            .sorted { $0.0.time < $1.0.time }

        return (
            lines: combined.map(\.0),
            characterTimes: combined.map(\.1)
        )
    }

    static func parseQQMusicQRC(_ qrc: String) -> (lines: [SyncedLine], characterTimes: [[Double]]) {
        var parsedLines: [SyncedLine] = []
        var parsedCharacterTimes: [[Double]] = []

        qrc.split(whereSeparator: \.isNewline).forEach { lineSub in
            let line = String(lineSub)
            guard line.first == "[",
                  let close = line.firstIndex(of: "]") else {
                return
            }

            let lineTiming = String(line[line.index(after: line.startIndex)..<close]).split(separator: ",")
            guard lineTiming.count >= 1,
                  let lineStartMS = Double(lineTiming[0]) else {
                return
            }

            let bodyStart = line.index(after: close)
            let body = String(line[bodyStart...])
            let segments = qrcTimedSegments(from: body, lineStart: lineStartMS / 1000)
            let text = segments.map(\.text).joined()
            let times = segments.map(\.time)

            if !text.isEmpty {
                parsedLines.append((lineStartMS / 1000, text))
                parsedCharacterTimes.append(times.count == text.count ? times : [])
            }
        }

        let combined = zip(parsedLines, parsedCharacterTimes)
            .sorted { $0.0.time < $1.0.time }

        return (
            lines: combined.map(\.0),
            characterTimes: combined.map(\.1)
        )
    }

    static func lines(fromPlainLyrics lyrics: String) -> [String] {
        lyrics
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func singleLine(fromPlainLyrics lyrics: String) -> String {
        lines(fromPlainLyrics: lyrics).first ?? ""
    }

    static func multiline(fromPlainLyrics lyrics: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        return lines(fromPlainLyrics: lyrics)
            .prefix(limit)
            .joined(separator: "\n")
    }

    static func displayFallback(isFetching: Bool) -> String {
        isFetching ? "Loading lyrics..." : "无歌词"
    }

    static func containsPersianScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return value >= 0x0600 && value <= 0x06FF
        }
    }

    static func currentSyncedIndex(from syncedLyrics: [(time: Double, text: String)], elapsed: Double) -> Int? {
        guard !syncedLyrics.isEmpty else { return nil }

        var low = 0
        var high = syncedLyrics.count - 1
        var index = 0

        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                index = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return index
    }

    static func activeCharacterIndex(from syncedLyrics: [(time: Double, text: String)], elapsed: Double) -> Int? {
        guard let progress = activeCharacterProgress(from: syncedLyrics, elapsed: elapsed) else {
            return nil
        }
        guard let lineIndex = currentSyncedIndex(from: syncedLyrics, elapsed: elapsed) else {
            return nil
        }

        let characterCount = syncedLyrics[lineIndex].text.count
        guard characterCount > 0 else { return nil }
        return min(characterCount - 1, Int(progress))
    }

    static func activeCharacterProgress(from syncedLyrics: [(time: Double, text: String)], elapsed: Double) -> Double? {
        guard let lineIndex = currentSyncedIndex(from: syncedLyrics, elapsed: elapsed) else {
            return nil
        }

        let text = syncedLyrics[lineIndex].text
        let characterCount = text.count
        guard characterCount > 0 else { return nil }

        let start = syncedLyrics[lineIndex].time
        let nextStart: Double
        if lineIndex + 1 < syncedLyrics.count {
            nextStart = syncedLyrics[lineIndex + 1].time
        } else {
            nextStart = start + max(2.0, Double(characterCount) * 0.18)
        }

        let duration = max(nextStart - start, 0.6)
        let progress = min(max((elapsed - start) / duration, 0), 0.999)
        return min(Double(characterCount - 1), progress * Double(characterCount))
    }

    static func activeLineProgress(from syncedLyrics: [(time: Double, text: String)], elapsed: Double, leadTime: Double = 0) -> Double? {
        guard let lineIndex = currentSyncedIndex(from: syncedLyrics, elapsed: elapsed) else {
            return nil
        }

        let text = syncedLyrics[lineIndex].text
        let start = syncedLyrics[lineIndex].time
        let nextStart: Double
        if lineIndex + 1 < syncedLyrics.count {
            nextStart = syncedLyrics[lineIndex + 1].time
        } else {
            nextStart = start + max(2.0, Double(text.count) * 0.18)
        }

        let duration = max(nextStart - start, 0.6)
        let adjustedElapsed = min(elapsed + leadTime, nextStart)
        let rawProgress = min(max((adjustedElapsed - start) / duration, 0), 1)
        return karaokeProgress(for: text, rawProgress: rawProgress, duration: duration)
    }

    static func activeLineProgress(
        from syncedLyrics: [(time: Double, text: String)],
        characterTimes: [[Double]],
        elapsed: Double,
        leadTime: Double = 0
    ) -> Double? {
        guard let lineIndex = currentSyncedIndex(from: syncedLyrics, elapsed: elapsed) else {
            return nil
        }

        let text = syncedLyrics[lineIndex].text
        let start = syncedLyrics[lineIndex].time
        let nextStart: Double
        if lineIndex + 1 < syncedLyrics.count {
            nextStart = syncedLyrics[lineIndex + 1].time
        } else {
            nextStart = start + max(2.0, Double(text.count) * 0.18)
        }

        let adjustedElapsed = min(elapsed + leadTime, nextStart)
        if characterTimes.indices.contains(lineIndex),
           let timedProgress = perCharacterProgress(
            text: text,
            characterTimes: characterTimes[lineIndex],
            elapsed: adjustedElapsed,
            lineEnd: nextStart
           ) {
            return timedProgress
        }

        return nil
    }

    static func karaokeProgress(for text: String, rawProgress: Double, duration: Double) -> Double {
        min(max(rawProgress, 0), 1)
    }

    private static func perCharacterProgress(
        text: String,
        characterTimes: [Double],
        elapsed: Double,
        lineEnd: Double
    ) -> Double? {
        let characterCount = text.count
        guard characterCount > 0, characterTimes.count == characterCount else {
            return nil
        }

        if elapsed <= characterTimes[0] {
            return 0
        }

        for index in 0..<characterCount {
            let start = characterTimes[index]
            let end = index + 1 < characterTimes.count ? characterTimes[index + 1] : lineEnd
            guard end > start else { continue }

            if elapsed < end {
                let local = min(max((elapsed - start) / (end - start), 0), 1)
                return (Double(index) + local) / Double(characterCount)
            }
        }

        return 1
    }

    private struct TimestampMatch {
        let value: String
        let endOffset: Int
    }

    private struct InlineTimedSegment {
        let time: Double
        let text: String
    }

    private static func firstTimestampMatch(in line: String, opening: Character, closing: Character) -> TimestampMatch? {
        guard line.first == opening,
              let closingIndex = line.firstIndex(of: closing) else {
            return nil
        }

        let rawValue = String(line[line.index(after: line.startIndex)..<closingIndex])
        let endOffset = line.distance(from: line.startIndex, to: line.index(after: closingIndex))
        return TimestampMatch(value: rawValue, endOffset: endOffset)
    }

    private static func inlineTimedSegments(from lyricBody: String) -> [InlineTimedSegment] {
        var segments: [InlineTimedSegment] = []
        var cursor = lyricBody.startIndex

        while cursor < lyricBody.endIndex {
            guard lyricBody[cursor] == "<",
                  let close = lyricBody[cursor...].firstIndex(of: ">") else {
                cursor = lyricBody.index(after: cursor)
                continue
            }

            let timestampText = String(lyricBody[lyricBody.index(after: cursor)..<close])
            guard let time = timestampValue(from: timestampText) else {
                cursor = lyricBody.index(after: close)
                continue
            }

            let textStart = lyricBody.index(after: close)
            var nextTimestamp = textStart
            while nextTimestamp < lyricBody.endIndex, lyricBody[nextTimestamp] != "<" {
                nextTimestamp = lyricBody.index(after: nextTimestamp)
            }

            let text = String(lyricBody[textStart..<nextTimestamp])
            if !text.isEmpty {
                segments.append(InlineTimedSegment(time: time, text: text))
            }
            cursor = nextTimestamp
        }

        return segments
    }

    private static func characterTimes(from segments: [InlineTimedSegment]) -> [Double] {
        var times: [Double] = []

        for index in segments.indices {
            let segment = segments[index]
            let characters = Array(segment.text)
            guard !characters.isEmpty else { continue }

            if characters.count == 1 {
                times.append(segment.time)
                continue
            }

            let nextTime = index + 1 < segments.count ? segments[index + 1].time : nil
            guard let nextTime, nextTime > segment.time else {
                times.append(contentsOf: Array(repeating: segment.time, count: characters.count))
                continue
            }

            let step = (nextTime - segment.time) / Double(characters.count)
            for characterIndex in characters.indices {
                times.append(segment.time + (Double(characterIndex) * step))
            }
        }

        return times
    }

    private static func qrcTimedSegments(from body: String, lineStart: Double) -> [InlineTimedSegment] {
        var segments: [InlineTimedSegment] = []
        var cursor = body.startIndex

        while cursor < body.endIndex {
            guard body[cursor] == "(",
                  let close = body[cursor...].firstIndex(of: ")") else {
                cursor = body.index(after: cursor)
                continue
            }

            let timing = String(body[body.index(after: cursor)..<close]).split(separator: ",")
            guard let offsetMS = timing.first.flatMap({ Double($0) }) else {
                cursor = body.index(after: close)
                continue
            }

            let textStart = body.index(after: close)
            var nextTiming = textStart
            while nextTiming < body.endIndex, body[nextTiming] != "(" {
                nextTiming = body.index(after: nextTiming)
            }

            let text = String(body[textStart..<nextTiming])
            if !text.isEmpty {
                let segmentStart = lineStart + (offsetMS / 1000)
                let characters = Array(text)
                for index in characters.indices {
                    segments.append(InlineTimedSegment(time: segmentStart, text: String(characters[index])))
                }
            }
            cursor = nextTiming
        }

        return segments
    }

    private static func timestampValue(from text: String) -> Double? {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else {
            return nil
        }

        return minutes * 60 + seconds
    }

    static func syncedWindow(from syncedLyrics: [(time: Double, text: String)], elapsed: Double, limit: Int = 3) -> [Line] {
        guard let currentIndex = currentSyncedIndex(from: syncedLyrics, elapsed: elapsed) else {
            return []
        }

        let safeLimit = max(limit, 1)
        let beforeCount = safeLimit / 2
        let afterCount = safeLimit - beforeCount - 1
        let startIndex = currentIndex - beforeCount
        let endIndex = currentIndex + afterCount

        return (startIndex...endIndex).map { index in
            let text = syncedLyrics.indices.contains(index) ? syncedLyrics[index].text : ""
            return Line(text: text, isCurrent: index == currentIndex)
        }
    }
}
