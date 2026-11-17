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
    let characterTimes = [
        [10.0, 11.0, 13.0, 16.0],
        [20.0, 21.0, 22.0, 23.0]
    ]

    let atTwelve = LyricsDisplayText.activeLineProgress(
        from: syncedLyrics,
        characterTimes: characterTimes,
        elapsed: 12
    ) ?? 0
    let atFifteen = LyricsDisplayText.activeLineProgress(
        from: syncedLyrics,
        characterTimes: characterTimes,
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
        LyricsDisplayText.activeLineProgress(from: syncedLyrics, characterTimes: [[], []], elapsed: 15),
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
            print("SevenIslandFeatureTests passed")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
