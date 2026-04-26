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

func testVSCodeStorageJsonParsesExistingLocalFoldersOnly() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let project = temp.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let storage = temp.appendingPathComponent("storage.json")
    let encodedPath = project.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    try """
    {
      "profileAssociations": {
        "workspaces": {
          "file://\(encodedPath)": "__default__profile__",
          "vscode-vfs://github/example/repo": "__default__profile__",
          "file:///definitely/not/here": "__default__profile__"
        }
      }
    }
    """.write(to: storage, atomically: true, encoding: .utf8)

    let service = VSCodeRecentProjectsService(
        storageJSONURL: storage,
        stateDatabaseURL: temp.appendingPathComponent("missing.vscdb")
    )

    let projects = service.loadProjects(includeMissing: false, limit: 30)
    expectEqual(projects.map { $0.url.standardizedFileURL.path }, [project.standardizedFileURL.path], "parses existing local VS Code folders")
    expectEqual(projects.first?.name, "Project", "uses folder name as display name")
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

@main
enum SevenIslandFeatureTestRunner {
    static func main() {
        do {
            testClipboardHistoryDeduplicatesAndFiltersSensitiveText()
            testClipboardHistoryRespectsMaximumItemLimit()
            try testVSCodeStorageJsonParsesExistingLocalFoldersOnly()
            testCodexRolloutActivityParsesToolAndQuota()
            testCodexRolloutParsesLastConversationTurn()
            testCodexRolloutParsesOpenLastConversationTurn()
            testCodexSnapshotFormatsQuotaFromActivity()
            testCodexSnapshotShowsClosedLiveActivityWhenWorking()
            print("SevenIslandFeatureTests passed")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
