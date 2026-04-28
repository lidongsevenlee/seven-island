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

    static func karaokeProgress(for text: String, rawProgress: Double, duration: Double) -> Double {
        let weights = text.map(karaokeWeight)
        guard !weights.isEmpty else { return 0 }

        let totalWeight = max(weights.reduce(0, +), 0.001)
        let attack = min(0.16, max(0.04, 0.18 / max(duration, 0.6)))
        let release = min(0.18, max(0.06, 0.24 / max(duration, 0.6)))
        let shaped = smoothstep(rawProgress)

        if shaped <= attack {
            return min(shaped / attack * 0.035, 0.035)
        }

        if shaped >= 1 - release {
            let tailProgress = (shaped - (1 - release)) / release
            return min(1, 0.94 + smoothstep(tailProgress) * 0.06)
        }

        let singingProgress = (shaped - attack) / max(1 - attack - release, 0.001)
        let targetWeight = singingProgress * totalWeight
        var consumed: Double = 0

        for (index, weight) in weights.enumerated() {
            let next = consumed + weight
            if targetWeight <= next {
                let local = (targetWeight - consumed) / max(weight, 0.001)
                let prefixWidth = Double(index) / Double(weights.count)
                return prefixWidth + smoothstep(local) / Double(weights.count)
            }
            consumed = next
        }

        return 1
    }

    private static func karaokeWeight(for character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return 0.28 }
        if CharacterSet.punctuationCharacters.contains(scalar) { return 0.36 }

        let value = scalar.value
        if (0x4E00...0x9FFF).contains(value) { return 1.16 }
        if (0x3040...0x30FF).contains(value) || (0xAC00...0xD7AF).contains(value) { return 1.12 }
        if CharacterSet.decimalDigits.contains(scalar) { return 0.76 }
        if CharacterSet.letters.contains(scalar) { return 0.72 }
        return 1
    }

    private static func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
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
