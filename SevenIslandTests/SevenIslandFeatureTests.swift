import Foundation
import Defaults
@testable import Seven_Island

@discardableResult
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) -> Bool {
    if actual != expected {
        fputs("FAIL: \(message)\n  expected: \(expected)\n  actual: \(actual)\n", stderr)
        exit(1)
    }
    return true
}

func testClipboardHistoryDeduplicatesAndFiltersSensitiveText() {
    let normal = ClipboardHistoryStore.nextItems(
        inserting: "hello island",
        into: [],
        limit: 5
    )
    expectEqual(normal.map(\.content), ["hello island"], "records normal clipboard text")

    let deduped = ClipboardHistoryStore.nextItems(
        inserting: "hello island",
        into: normal,
        limit: 5
    )
    expectEqual(deduped.count, 1, "deduplicates repeated clipboard text")

    let sensitive = ClipboardHistoryStore.nextItems(
        inserting: "sk-proj-1234567890abcdefghijklmnopqrstuvwxyz",
        into: deduped,
        limit: 5
    )
    expectEqual(sensitive.map(\.content), ["hello island"], "filters sensitive-looking text")
}

func testClipboardHistoryRespectsMaximumItemLimit() {
    var items: [ClipboardHistoryItem] = []
    for index in 0..<6 {
        items = ClipboardHistoryStore.nextItems(
            inserting: "item \(index)",
            into: items,
            limit: 3
        )
    }

    expectEqual(items.map(\.content), ["item 5", "item 4", "item 3"], "keeps newest items up to limit")
}

func testVSCodeProjectsLoadsFirstLevelProjectsDirectoryFoldersOnly() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let projectsDirectory = temp.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)

    let beta = projectsDirectory.appendingPathComponent("Beta", isDirectory: true)
    let alpha = projectsDirectory.appendingPathComponent("Alpha", isDirectory: true)
    let hidden = projectsDirectory.appendingPathComponent(".Hidden", isDirectory: true)
    let nested = beta.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "not a folder".write(to: projectsDirectory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    let service = VSCodeRecentProjectsService(
        storageJSONURL: temp.appendingPathComponent("missing-storage.json"),
        stateDatabaseURL: temp.appendingPathComponent("missing.vscdb")
    )

    let previousDepth = Defaults[.vscodeScanDepth]
    let previousIncludeHidden = Defaults[.vscodeIncludeHidden]
    Defaults[.vscodeScanDepth] = 1
    Defaults[.vscodeIncludeHidden] = false
    defer {
        Defaults[.vscodeScanDepth] = previousDepth
        Defaults[.vscodeIncludeHidden] = previousIncludeHidden
    }
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: alpha.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: beta.path)
    let projects = service.loadProjects(from: projectsDirectory, includeMissing: false, limit: 30)
    expectEqual(
        projects.map { $0.url.standardizedFileURL.path },
        [alpha.standardizedFileURL.path, beta.standardizedFileURL.path],
        "loads first-level project folders by modification time"
    )
    expectEqual(projects.first?.name, "Alpha", "uses folder name as display name")
}

func testLyricsDisplayTextBuildsSingleAndMultilineLyrics() {
    let plainLyrics = """

    First line

    Second line
    Third line
    Fourth line
    """

    expectEqual(
        LyricsDisplayText.singleLine(fromPlainLyrics: plainLyrics),
        "First line",
        "closed notch uses the first non-empty plain lyric line"
    )
    expectEqual(
        LyricsDisplayText.multiline(fromPlainLyrics: plainLyrics, limit: 3),
        "First line\nSecond line\nThird line",
        "expanded home limits plain lyrics to multiple readable lines"
    )
}

func testLyricsDisplayTextCentersCurrentSyncedLyricInWindow() {
    let syncedLyrics: [(time: Double, text: String)] = [
        (0, "Before"),
        (10, "Current"),
        (20, "After"),
        (30, "Later")
    ]

    let window = LyricsDisplayText.syncedWindow(from: syncedLyrics, elapsed: 12)
    expectEqual(window.map(\.text), ["Before", "Current", "After"], "expanded synced lyrics centers the current line")
    expectEqual(window.map(\.isCurrent), [false, true, false], "marks only the center current lyric as active")
}

func testLyricsDisplayTextEstimatesActiveCharacter() {
    let syncedLyrics: [(time: Double, text: String)] = [
        (10, "Hello"),
        (20, "World")
    ]

    expectEqual(
        LyricsDisplayText.activeCharacterIndex(from: syncedLyrics, elapsed: 10),
        0,
        "starts the character pulse at the first character"
    )
    expectEqual(
        LyricsDisplayText.activeCharacterIndex(from: syncedLyrics, elapsed: 15),
        2,
        "moves the character pulse through the lyric line over time"
    )
    expectEqual(
        LyricsDisplayText.activeCharacterIndex(from: syncedLyrics, elapsed: 19.9),
        4,
        "keeps the active character inside the current lyric line"
    )
}

func testLyricsDisplayTextUsesLineTimingForKaraokeProgress() {
    let karaokeHalf = LyricsDisplayText.karaokeProgress(
        for: "我靜靜悄悄默默淡淡的止住呼吸",
        rawProgress: 0.5,
        duration: 4
    )
    let karaokeStart = LyricsDisplayText.karaokeProgress(
        for: "慢慢的流",
        rawProgress: 0.04,
        duration: 3
    )

    expectEqual(karaokeHalf, 0.5, "keeps karaoke progress exactly on the line midpoint")
    expectEqual(karaokeStart, 0.04, "does not hold the start ahead of the sung timing")
}

func testLyricsDisplayTextKeepsKaraokeProgressLockedToLineTiming() {
    let lyric = "Strict rhythm matching"

    let firstQuarter = LyricsDisplayText.karaokeProgress(
        for: lyric,
        rawProgress: 0.25,
        duration: 4
    )
    let midpoint = LyricsDisplayText.karaokeProgress(
        for: lyric,
        rawProgress: 0.5,
        duration: 4
    )
    let thirdQuarter = LyricsDisplayText.karaokeProgress(
        for: lyric,
        rawProgress: 0.75,
        duration: 4
    )

    expectEqual(abs(firstQuarter - 0.25) < 0.03, true, "keeps first-quarter lyric progress locked to elapsed timing")
    expectEqual(abs(midpoint - 0.5) < 0.03, true, "keeps midpoint lyric progress locked to elapsed timing")
    expectEqual(abs(thirdQuarter - 0.75) < 0.03, true, "keeps third-quarter lyric progress locked to elapsed timing")
}

func testLyricsDisplayTextUsesPerCharacterTimestampsWhenAvailable() {
    let syncedLyrics: [(time: Double, text: String)] = [
        (10, "ABCD"),
        (20, "Next")
    ]
    let characterTimings = [
        [10.0, 11.0, 13.0, 16.0],
        [20.0, 21.0, 22.0, 23.0]
    ].map { $0.map { LyricsDisplayText.CharacterTiming(start: $0) } }

    let atTwelve = LyricsDisplayText.activeLineProgress(
        from: syncedLyrics,
        characterTimings: characterTimings,
        elapsed: 12
    ) ?? 0
    let atFifteen = LyricsDisplayText.activeLineProgress(
        from: syncedLyrics,
        characterTimings: characterTimings,
        elapsed: 15
    ) ?? 0

    expectEqual(abs(atTwelve - 0.375) < 0.001, true, "uses the B-to-C timing interval instead of line-average timing")
    expectEqual(abs(atFifteen - 0.6666666667) < 0.001, true, "uses the C-to-D timing interval instead of line-average timing")
}

func testLyricsDisplayTextDoesNotAnimateWithoutPerCharacterTimestamps() {
    let syncedLyrics: [(time: Double, text: String)] = [
        (10, "Line only"),
        (20, "Next")
    ]

    expectEqual(
        LyricsDisplayText.activeLineProgress(from: syncedLyrics, characterTimings: [[], []], elapsed: 15),
        nil,
        "does not synthesize progress animation from line-only lyrics"
    )
}

func testLyricsDisplayTextParsesEnhancedLRCCharacterTimestamps() {
    let parsed = LyricsDisplayText.parseSyncedLyrics(
        "[00:10.00]<00:10.00>你<00:10.50>好<00:11.20>世<00:11.70>界"
    )

    expectEqual(parsed.lines.map(\.text), ["你好世界"], "removes enhanced LRC inline timestamps from display text")
    expectEqual(parsed.characterTimes, [[10.0, 10.5, 11.2, 11.7]], "keeps one timestamp per displayed character")
}

func testLyricsDisplayTextParsesQRCCharacterTimestamps() {
    let parsed = LyricsDisplayText.parseQQMusicQRC("[10000,3000](0,500)你(500,700)好(1200,600)世(1800,700)界")

    expectEqual(parsed.lines.map(\.text), ["你好世界"], "removes QRC inline timestamps from display text")
    expectEqual(parsed.characterTimes, [[10.0, 10.5, 11.2, 11.8]], "converts QRC word offsets into absolute character timestamps")
}

func testAppleMusicAccessibilityLyricsValidatesCompleteTiming() {
    typealias Row = AppleMusicAccessibilityLyrics.Row
    let plain = Row(text: "First line", timeLabels: [])
    let first = Row(text: "First line", timeLabels: ["00:12.50"])
    let second = Row(text: "[00:15.25]Second line", timeLabels: [])
    let timed = AppleMusicAccessibilityLyrics(rows: [first, second], duration: 90)
    expectEqual(timed?.text, "First line\nSecond line", "keeps the Apple Music line text")
    expectEqual(timed?.syncedLines.map(\.time), [12.5, 15.25], "reads explicit line timestamps")
    expectEqual(AppleMusicAccessibilityLyrics(rows: [plain, second], duration: 90)?.syncedLines.count, 0, "leaves partial timing to a fallback")
    expectEqual(AppleMusicAccessibilityLyrics(rows: [second, first], duration: 90)?.syncedLines.count, 0, "rejects reversed timing")
    expectEqual(AppleMusicAccessibilityLyrics(rows: [first, second], duration: 13)?.syncedLines.count, 0, "rejects timing beyond the current track")
}

func testAppleMusicCachedLyricsParsesAppleTimestampFormats() {
    let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="17.948" end="23.010"><span>First</span> line</p>
        <p begin="1:01.165" end="1:05.000">Second line</p>
        </div></body></tt>
        """
    let lines = AppleMusicCachedLyrics.parseTTML(ttml, duration: 90)?.lines ?? []
    expectEqual(lines.map(\.time), [17.948, 61.165], "reads decimal and clock timestamps in the same TTML")
    expectEqual(lines.map(\.text), ["First line", "Second line"], "joins lyric spans into line text")
    expectEqual(LyricsDisplayText.currentSyncedIndex(from: lines, elapsed: 61.164), 0, "holds the preceding line")
    expectEqual(LyricsDisplayText.currentSyncedIndex(from: lines, elapsed: 61.165), 1, "switches on the TTML line time")
    expectEqual(AppleMusicCachedLyrics.parseTTML(ttml, duration: 60)?.lines.count, nil, "rejects timestamps beyond the track")
}

func testAppleMusicCachedLyricsFollowsTimedSpans() {
    let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="10.0" end="14.0"> <span begin="10.0" end="10.5">你</span><span begin="12.0" end="13.0"><span>好</span>啊</span> </p>
        <p begin="20.0" end="21.0">下一句</p>
        </div></body></tt>
        """
    let timeline = AppleMusicCachedLyrics.parseTTML(ttml, duration: 30)
    expectEqual(timeline?.lines.map(\.text), ["你好啊", "下一句"], "preserves the text of timed spans")
    expectEqual(timeline?.characterTimings.first?.map(\.start), [10, 12, 12.5], "uses the absolute span starts")
    expectEqual(timeline?.characterTimings.first?.map(\.end), [10.5, 12.5, 13], "retains end times for the animation")
    expectEqual(timeline?.characterTimings.last, [], "preserves line-only timing")

    for (elapsed, expected) in [(10.25, 1.0 / 6), (11, 1.0 / 3), (12.5, 2.0 / 3), (13.1, 1), (11, 1.0 / 3)] {
        let progress = LyricsDisplayText.activeLineProgress(
            from: timeline?.lines ?? [],
            characterTimings: timeline?.characterTimings ?? [],
            elapsed: elapsed
        )
        expectEqual(progress.map { abs($0 - expected) < 0.001 }, true, "follows the playback position at \(elapsed) seconds")
    }
}

func testLyricsDisplayTextChecksFallbackRecordingTiming() {
    let official: [LyricsDisplayText.SyncedLine] = [(10, "第一句。"), (14, "第二句"), (22, "第三句")]
    let sameRecording: [LyricsDisplayText.SyncedLine] = [(10.2, "第一句"), (14.1, "第二句"), (22.5, "第 三 句")]
    let differentRecording = sameRecording.map { (time: $0.time + 2, text: $0.text) }

    expectEqual(LyricsDisplayText.matchesPlaybackTimeline(sameRecording, reference: official), true, "accepts matching text and timing")
    expectEqual(LyricsDisplayText.matchesPlaybackTimeline(differentRecording, reference: official), false, "rejects shifted recordings")
    expectEqual(LyricsDisplayText.matchesPlaybackTimeline(Array(sameRecording.prefix(1)), reference: official), false, "requires more than one common line")
}

func testLyricsDisplayTextRejectsSameTitleWithDifferentWords() {
    let official = "镜子里的微笑\n灯下看见你的名字\n还记得那年冬天\nLinda, Linda"
    let differentVersion: [LyricsDisplayText.SyncedLine] = [
        (12, "明月照街头"), (16, "风吹过窗边"), (20, "再会我的朋友"), (24, "LINDA LINDA")
    ]
    let sameVersion: [LyricsDisplayText.SyncedLine] = [
        (12, "鏡子裡的微笑"), (16, "燈下看見妳的名字"), (20, "還記得那年冬天"), (24, "LINDA LINDA")
    ]

    expectEqual(LyricsDisplayText.matchesLyricText(differentVersion, reference: official), false, "rejects a shared title and different verses")
    expectEqual(LyricsDisplayText.matchesLyricText(sameVersion, reference: official), true, "matches punctuation and traditional Chinese variants")
}

func testLyricsDisplayTextProvidesUnavailableFallback() {
    expectEqual(
        LyricsDisplayText.displayFallback(isFetching: false),
        "无歌词",
        "uses localized no-lyrics placeholder when lookup finishes without text"
    )
    expectEqual(
        LyricsDisplayText.displayFallback(isFetching: true),
        "Loading lyrics...",
        "keeps loading state visible during lookup"
    )
}

@main
enum SevenIslandFeatureTestRunner {
    static func main() {
        do {
            testClipboardHistoryDeduplicatesAndFiltersSensitiveText()
            testClipboardHistoryRespectsMaximumItemLimit()
            try testVSCodeProjectsLoadsFirstLevelProjectsDirectoryFoldersOnly()
            testLyricsDisplayTextBuildsSingleAndMultilineLyrics()
            testLyricsDisplayTextCentersCurrentSyncedLyricInWindow()
            testLyricsDisplayTextEstimatesActiveCharacter()
            testLyricsDisplayTextUsesLineTimingForKaraokeProgress()
            testLyricsDisplayTextKeepsKaraokeProgressLockedToLineTiming()
            testLyricsDisplayTextUsesPerCharacterTimestampsWhenAvailable()
            testLyricsDisplayTextDoesNotAnimateWithoutPerCharacterTimestamps()
            testLyricsDisplayTextParsesEnhancedLRCCharacterTimestamps()
            testLyricsDisplayTextParsesQRCCharacterTimestamps()
            testLyricsDisplayTextProvidesUnavailableFallback()
            testAppleMusicAccessibilityLyricsValidatesCompleteTiming()
            testAppleMusicCachedLyricsParsesAppleTimestampFormats()
            testAppleMusicCachedLyricsFollowsTimedSpans()
            testLyricsDisplayTextChecksFallbackRecordingTiming()
            testLyricsDisplayTextRejectsSameTitleWithDifferentWords()
            print("SevenIslandFeatureTests passed")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
