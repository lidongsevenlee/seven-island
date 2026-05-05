import Foundation

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
        stateDatabaseURL: temp.appendingPathComponent("missing.vscdb"),
        projectsDirectoryURL: projectsDirectory
    )

    let projects = service.loadProjects(includeMissing: false, limit: 30)
    expectEqual(
        projects.map { $0.url.standardizedFileURL.path },
        [alpha.standardizedFileURL.path, beta.standardizedFileURL.path],
        "loads sorted first-level folders from Projects only"
    )
    expectEqual(projects.first?.name, "Alpha", "uses folder name as display name")
}

func testCodexRolloutActivityParsesToolAndQuota() {
    let now = Date(timeIntervalSince1970: 1_777_189_700)
    let lines = [
        """
        {"timestamp":"2026-04-26T07:41:20.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"npm test -- --watch=false\\"}"}}
        """,
        """
        {"timestamp":"2026-04-26T07:41:30.000Z","type":"token_count","rate_limits":{"primary":{"used_percent":12.4},"secondary":{"used_percent":60.0},"credits":{"has_credits":false,"balance":"0"},"plan_type":"plus"}}
        """
    ]

    let activity = CodexStatusService.activity(
        fromRolloutLines: lines,
        sessionUpdatedAt: Date(timeIntervalSince1970: 1_777_189_600),
        now: now
    )

    expectEqual(activity.state, .working, "marks recent rollout activity as working")
    expectEqual(activity.headline, "npm test -- --watch=false", "extracts the latest command summary")
    expectEqual(activity.lastToolName, "Shell", "formats Codex tool name")
    expectEqual(activity.primaryLimitDisplayText, "12%", "formats primary Codex rate limit")
    expectEqual(activity.secondaryLimitDisplayText, "60%", "formats secondary Codex rate limit")
    expectEqual(activity.creditsDisplayText, "Credits 0", "formats Codex credits")
}

func testCodexRolloutParsesLastConversationTurn() {
    let lines = [
        """
        {"timestamp":"2026-04-26T07:40:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"old request"}]}}
        """,
        """
        {"timestamp":"2026-04-26T07:40:20.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"old response"}]}}
        """,
        """
        {"timestamp":"2026-04-26T07:41:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"show the last round"},{"type":"input_image","image_url":"data:image/png;base64,ignored"}]}}
        """,
        """
        {"timestamp":"2026-04-26T07:41:20.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"here is the final answer"}]}}
        """
    ]

    let turn = CodexStatusService.lastConversationTurn(fromRolloutLines: lines)
    expectEqual(turn?.userText, "show the last round", "extracts the latest user message")
    expectEqual(turn?.assistantText, "here is the final answer", "extracts the latest assistant message")
}

func testCodexRolloutParsesOpenLastConversationTurn() {
    let lines = [
        """
        {"timestamp":"2026-04-26T07:41:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"expand the panel"}]}}
        """
    ]

    let turn = CodexStatusService.lastConversationTurn(fromRolloutLines: lines)
    expectEqual(turn?.userText, "expand the panel", "keeps the latest user message when Codex has not replied yet")
    expectEqual(turn?.assistantText, nil, "leaves assistant text empty for an open turn")
}

func testCodexSnapshotFormatsQuotaFromActivity() {
    let activity = CodexWorkActivity(
        state: .idle,
        headline: "Codex is idle",
        detail: "Last update 2h ago",
        lastToolName: nil,
        updatedAt: Date(timeIntervalSince1970: 1_777_189_644),
        primaryLimitUsedPercent: 25,
        secondaryLimitUsedPercent: nil,
        creditsBalance: "0",
        hasCredits: false,
        planType: "plus"
    )
    let snapshot = CodexStatusSnapshot(
        recentSessions: [
            CodexSessionSummary(
                id: "thread-1",
                title: "Build Seven Island",
                cwd: "/tmp/seven-island",
                updatedAt: Date(timeIntervalSince1970: 1_777_189_644),
                tokensUsed: 12_345,
                model: "gpt-5.5",
                reasoningEffort: "high",
                rolloutPath: nil,
                activity: activity,
                lastTurn: nil
            )
        ],
        totalThreads: 4,
        totalTokensUsed: 98_765,
        codexCLIStatus: "codex-cli 0.122.0",
        codexAppVersion: "26.422.30944",
        isAuthFilePresent: true,
        isDeviceBindingPresent: false
    )

    expectEqual(snapshot.quotaDisplayText, "Limit 25%", "formats quota from rollout rate limit")
    expectEqual(snapshot.totalTokensDisplayText, "98,765 tokens", "formats total token usage")
    expectEqual(snapshot.authorizationDisplayText, "Auth file present", "formats auth state")
    expectEqual(snapshot.shouldShowClosedLiveActivity, false, "does not show closed Codex activity for idle sessions")
}

func testCodexSnapshotShowsClosedLiveActivityWhenWorking() {
    let activity = CodexWorkActivity(
        state: .working,
        headline: "Using Shell",
        detail: "Codex is executing Shell",
        lastToolName: "Shell",
        updatedAt: Date(timeIntervalSince1970: 1_777_189_644),
        primaryLimitUsedPercent: nil,
        secondaryLimitUsedPercent: nil,
        creditsBalance: nil,
        hasCredits: nil,
        planType: nil
    )
    let snapshot = CodexStatusSnapshot(
        recentSessions: [
            CodexSessionSummary(
                id: "thread-2",
                title: "Run build",
                cwd: "/tmp/seven-island",
                updatedAt: Date(timeIntervalSince1970: 1_777_189_644),
                tokensUsed: 123,
                model: "gpt-5.5",
                reasoningEffort: "medium",
                rolloutPath: nil,
                activity: activity,
                lastTurn: nil
            )
        ],
        totalThreads: 1,
        totalTokensUsed: 123,
        codexCLIStatus: "codex-cli 0.122.0",
        codexAppVersion: nil,
        isAuthFilePresent: true,
        isDeviceBindingPresent: true
    )

    expectEqual(snapshot.shouldShowClosedLiveActivity, true, "shows closed Codex activity while Codex is working")
}

func testCodexSnapshotFiltersActiveSessions() {
    let active = CodexSessionSummary(
        id: "active-thread",
        title: "Active",
        cwd: "/tmp/seven-island",
        updatedAt: Date(timeIntervalSince1970: 1_777_189_700),
        tokensUsed: 100,
        model: "gpt-5.5",
        reasoningEffort: "medium",
        rolloutPath: nil,
        activity: CodexWorkActivity(
            state: .working,
            headline: "Running tests",
            detail: "Codex is executing Shell",
            lastToolName: "Shell",
            updatedAt: Date(timeIntervalSince1970: 1_777_189_700),
            primaryLimitUsedPercent: nil,
            secondaryLimitUsedPercent: nil,
            creditsBalance: nil,
            hasCredits: nil,
            planType: nil
        ),
        lastTurn: CodexConversationTurn(userText: "Please test it", assistantText: "Running tests now")
    )
    let idle = CodexSessionSummary(
        id: "idle-thread",
        title: "Idle",
        cwd: "/tmp/seven-island",
        updatedAt: Date(timeIntervalSince1970: 1_777_189_600),
        tokensUsed: 50,
        model: "gpt-5.5",
        reasoningEffort: "medium",
        rolloutPath: nil,
        activity: CodexWorkActivity(
            state: .idle,
            headline: "Codex is idle",
            detail: "Last update 10m ago",
            lastToolName: nil,
            updatedAt: Date(timeIntervalSince1970: 1_777_189_600),
            primaryLimitUsedPercent: nil,
            secondaryLimitUsedPercent: nil,
            creditsBalance: nil,
            hasCredits: nil,
            planType: nil
        ),
        lastTurn: nil
    )
    let snapshot = CodexStatusSnapshot(
        recentSessions: [idle, active],
        totalThreads: 2,
        totalTokensUsed: 150,
        codexCLIStatus: "codex-cli",
        codexAppVersion: nil,
        isAuthFilePresent: true,
        isDeviceBindingPresent: true
    )

    expectEqual(snapshot.activeSessions.map(\.id), ["active-thread"], "Codex panel shows only active working sessions")
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

func testCodexSessionURLUsesLocalConversationRoute() {
    let url = AppLauncherService.codexSessionURL(for: "7d8f927e-32b5-4c1d-9a31-8dcf53b8d4ef")
    expectEqual(url?.absoluteString, "codex://threads/7d8f927e-32b5-4c1d-9a31-8dcf53b8d4ef", "builds Codex local conversation deeplink")

    let invalidURL = AppLauncherService.codexSessionURL(for: "thread abc/1")
    expectEqual(invalidURL?.absoluteString, nil, "rejects Codex deeplinks that Codex Desktop will ignore")
}

@main
enum SevenIslandFeatureTestRunner {
    static func main() {
        do {
            testClipboardHistoryDeduplicatesAndFiltersSensitiveText()
            testClipboardHistoryRespectsMaximumItemLimit()
            try testVSCodeProjectsLoadsFirstLevelProjectsDirectoryFoldersOnly()
            testCodexRolloutActivityParsesToolAndQuota()
            testCodexRolloutParsesLastConversationTurn()
            testCodexRolloutParsesOpenLastConversationTurn()
            testCodexSnapshotFormatsQuotaFromActivity()
            testCodexSnapshotShowsClosedLiveActivityWhenWorking()
            testCodexSnapshotFiltersActiveSessions()
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
            testCodexSessionURLUsesLocalConversationRoute()
            print("SevenIslandFeatureTests passed")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
