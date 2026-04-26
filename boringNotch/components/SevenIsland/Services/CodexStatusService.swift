import Foundation

final class CodexStatusService: ObservableObject {
    static let shared = CodexStatusService()

    @Published private(set) var snapshot: CodexStatusSnapshot = .empty

    private let codexDirectory: URL
    private let currentWorkspacePath: String
    private var isRefreshing = false

    init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        currentWorkspacePath: String = FileManager.default.currentDirectoryPath
    ) {
        self.codexDirectory = codexDirectory
        self.currentWorkspacePath = currentWorkspacePath
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let codexDirectory = codexDirectory
        let currentWorkspacePath = currentWorkspacePath

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Self.loadSnapshot(
                codexDirectory: codexDirectory,
                currentWorkspacePath: currentWorkspacePath
            )

            DispatchQueue.main.async {
                self?.snapshot = snapshot
                self?.isRefreshing = false
            }
        }
    }

    func openCodex() {
        AppLauncherService.openCodexApp()
    }

    func openCodex(session: CodexSessionSummary) {
        AppLauncherService.openCodexSession(id: session.id)
    }

    private static func loadSnapshot(codexDirectory: URL, currentWorkspacePath: String) -> CodexStatusSnapshot {
        let databaseURL = codexDirectory.appendingPathComponent("state_5.sqlite")
        let authURL = codexDirectory.appendingPathComponent("auth.json")
        let sessions = loadRecentSessions(databaseURL: databaseURL)
        let totals = loadTotals(databaseURL: databaseURL)

        return CodexStatusSnapshot(
            recentSessions: preferCurrentWorkspaceSessions(sessions, currentWorkspacePath: currentWorkspacePath),
            totalThreads: totals.threads,
            totalTokensUsed: totals.tokens,
            codexCLIStatus: loadCLIStatus(),
            codexAppVersion: loadCodexAppVersion(),
            isAuthFilePresent: FileManager.default.fileExists(atPath: authURL.path),
            isDeviceBindingPresent: loadDeviceBindingCount(databaseURL: databaseURL) > 0
        )
    }

    private static func preferCurrentWorkspaceSessions(
        _ sessions: [CodexSessionSummary],
        currentWorkspacePath: String
    ) -> [CodexSessionSummary] {
        let current = sessions.filter { $0.cwd == currentWorkspacePath }
        if current.isEmpty {
            return Array(sessions.prefix(5))
        }
        return Array((current + sessions.filter { $0.cwd != currentWorkspacePath }).prefix(5))
    }

    private static func loadRecentSessions(databaseURL: URL) -> [CodexSessionSummary] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        let rolloutSelect = Self.hasColumn("rollout_path", in: "threads", databaseURL: databaseURL)
            ? "coalesce(rollout_path,'')"
            : "''"
        let query = """
        select id, replace(title, char(31), ' '), replace(cwd, char(31), ' '), updated_at, tokens_used, coalesce(model,''), coalesce(reasoning_effort,''), \(rolloutSelect)
        from threads
        where archived = 0
        order by updated_at desc
        limit 12;
        """

        return Self.runSQLite(databaseURL: databaseURL, query: query)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 8,
                      let updatedAt = TimeInterval(parts[3]),
                      let tokensUsed = Int(parts[4]) else {
                    return nil
                }

                let updatedDate = Date(timeIntervalSince1970: updatedAt)
                let rolloutPath = parts[7].isEmpty ? nil : parts[7]
                let rolloutInsights = Self.loadRolloutInsights(
                    rolloutPath: rolloutPath,
                    sessionUpdatedAt: updatedDate
                )
                return CodexSessionSummary(
                    id: parts[0],
                    title: parts[1].isEmpty ? "Untitled session" : parts[1],
                    cwd: parts[2],
                    updatedAt: updatedDate,
                    tokensUsed: tokensUsed,
                    model: parts[5].isEmpty ? nil : parts[5],
                    reasoningEffort: parts[6].isEmpty ? nil : parts[6],
                    rolloutPath: rolloutPath,
                    activity: rolloutInsights.activity,
                    lastTurn: rolloutInsights.lastTurn
                )
            }
    }

    private static func loadTotals(databaseURL: URL) -> (threads: Int, tokens: Int) {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return (0, 0)
        }

        let output = Self.runSQLite(
            databaseURL: databaseURL,
            query: "select count(*), coalesce(sum(tokens_used), 0) from threads;"
        )
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}")
        guard parts.count >= 2,
              let threads = Int(parts[0]),
              let tokens = Int(parts[1]) else {
            return (0, 0)
        }
        return (threads, tokens)
    }

    private static func loadDeviceBindingCount(databaseURL: URL) -> Int {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return 0
        }

        let output = Self.runSQLite(databaseURL: databaseURL, query: "select count(*) from device_key_bindings;")
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func loadCLIStatus() -> String {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "Codex CLI not found"
        }

        let output = Self.runProcess(executable: executable, arguments: ["--version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "Codex CLI installed" : output
    }

    private static func loadCodexAppVersion() -> String? {
        let plistURL = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Info.plist")
        guard let dictionary = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            return nil
        }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    private static func loadRolloutInsights(
        rolloutPath: String?,
        sessionUpdatedAt: Date
    ) -> (activity: CodexWorkActivity?, lastTurn: CodexConversationTurn?) {
        guard let rolloutPath else {
            return (
                CodexWorkActivity(
                    state: .idle,
                    headline: "No rollout log",
                    detail: "Open Codex to inspect this session",
                    lastToolName: nil,
                    updatedAt: sessionUpdatedAt,
                    primaryLimitUsedPercent: nil,
                    secondaryLimitUsedPercent: nil,
                    creditsBalance: nil,
                    hasCredits: nil,
                    planType: nil
                ),
                nil
            )
        }

        let url = URL(fileURLWithPath: rolloutPath)
        let lines = recentRolloutLines(from: url, limit: 180)
        guard !lines.isEmpty else {
            return (nil, nil)
        }
        return (
            activity(fromRolloutLines: lines, sessionUpdatedAt: sessionUpdatedAt),
            lastConversationTurn(fromRolloutLines: lines)
        )
    }

    static func activity(
        fromRolloutLines lines: [String],
        sessionUpdatedAt: Date,
        now: Date = Date()
    ) -> CodexWorkActivity {
        var latestTimestamp = sessionUpdatedAt
        var lastToolName: String?
        var headline: String?
        var detail: String?
        var primaryLimitUsedPercent: Double?
        var secondaryLimitUsedPercent: Double?
        var creditsBalance: String?
        var hasCredits: Bool?
        var planType: String?

        for line in lines {
            if line.contains("\"type\":\"message\"") {
                continue
            }

            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let timestamp = parseTimestamp(json["timestamp"]) {
                latestTimestamp = max(latestTimestamp, timestamp)
            }

            let payload = json["payload"] as? [String: Any]
            let item = payload ?? json["item"] as? [String: Any] ?? json
            let eventType = json["type"] as? String
            let itemType = item["type"] as? String

            if eventType == "response_item", itemType == "function_call" {
                let toolName = item["name"] as? String ?? "tool"
                lastToolName = friendlyToolName(toolName)
                let command = commandSummary(from: item["arguments"])
                headline = command ?? "Using \(lastToolName ?? toolName)"
                detail = "Codex is executing \(lastToolName ?? toolName)"
            } else if eventType == "event_msg", itemType == "exec_command_end" {
                if let status = item["status"] as? String {
                    detail = "Shell command \(status)"
                }
            }

            let rateLimits = (json["rate_limits"] as? [String: Any]) ?? (payload?["rate_limits"] as? [String: Any])
            if let rateLimits {
                primaryLimitUsedPercent = usedPercent(in: rateLimits["primary"])
                secondaryLimitUsedPercent = usedPercent(in: rateLimits["secondary"])
                if let credits = rateLimits["credits"] as? [String: Any] {
                    creditsBalance = stringValue(credits["balance"])
                    hasCredits = credits["has_credits"] as? Bool
                }
                planType = stringValue(rateLimits["plan_type"])
            }
        }

        let isRecent = now.timeIntervalSince(latestTimestamp) <= 10 * 60
        let state: CodexWorkState = isRecent ? .working : .idle
        let fallbackHeadline = isRecent ? "Codex is working" : "Codex is idle"

        return CodexWorkActivity(
            state: state,
            headline: headline ?? fallbackHeadline,
            detail: detail ?? "Last update \(relativeAge(from: latestTimestamp, to: now))",
            lastToolName: lastToolName,
            updatedAt: latestTimestamp,
            primaryLimitUsedPercent: primaryLimitUsedPercent,
            secondaryLimitUsedPercent: secondaryLimitUsedPercent,
            creditsBalance: creditsBalance,
            hasCredits: hasCredits,
            planType: planType
        )
    }

    static func lastConversationTurn(fromRolloutLines lines: [String]) -> CodexConversationTurn? {
        var currentUserText: String?
        var currentAssistantText: String?
        var lastTurn: CodexConversationTurn?

        for line in lines {
            if let rawMessage = rawConversationMessage(from: line) {
                let text = sanitizeConversationText(rawMessage.text)
                guard !text.isEmpty else { continue }

                if rawMessage.role == "user" {
                    currentUserText = text
                    currentAssistantText = nil
                    lastTurn = CodexConversationTurn(userText: currentUserText, assistantText: nil)
                } else {
                    currentAssistantText = text
                    lastTurn = CodexConversationTurn(
                        userText: currentUserText,
                        assistantText: currentAssistantText
                    )
                }
                continue
            }

            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let payload = json["payload"] as? [String: Any]
            let item = payload ?? json["item"] as? [String: Any] ?? json
            let eventType = json["type"] as? String
            let itemType = item["type"] as? String
            let role = item["role"] as? String ?? payload?["role"] as? String

            let messageRole: String?
            if itemType == "message", role == "user" || role == "assistant" {
                messageRole = role
            } else if eventType == "user_message" {
                messageRole = "user"
            } else if eventType == "assistant_message" {
                messageRole = "assistant"
            } else {
                messageRole = nil
            }

            guard let messageRole,
                  let text = conversationText(from: item).map(sanitizeConversationText),
                  !text.isEmpty else {
                continue
            }

            if messageRole == "user" {
                currentUserText = text
                currentAssistantText = nil
                lastTurn = CodexConversationTurn(userText: currentUserText, assistantText: nil)
            } else {
                currentAssistantText = text
                if currentUserText != nil || currentAssistantText != nil {
                    lastTurn = CodexConversationTurn(
                        userText: currentUserText,
                        assistantText: currentAssistantText
                    )
                }
            }
        }

        return lastTurn?.hasContent == true ? lastTurn : nil
    }

    private static func rawConversationMessage(from line: String) -> (role: String, text: String)? {
        guard line.contains("\"type\":\"message\"") else {
            return nil
        }

        let role: String
        if line.contains("\"role\":\"user\"") {
            role = "user"
        } else if line.contains("\"role\":\"assistant\"") {
            role = "assistant"
        } else {
            return nil
        }

        let textTypes = role == "user" ? ["input_text"] : ["output_text"]
        let text = textTypes
            .flatMap { extractJSONTextValues(in: line, fragmentType: $0) }
            .joined(separator: "\n")

        return text.isEmpty ? nil : (role, text)
    }

    private static func extractJSONTextValues(in line: String, fragmentType: String) -> [String] {
        let escapedType = NSRegularExpression.escapedPattern(for: fragmentType)
        let pattern = #"\{"type":"# + "\"\(escapedType)\"" + #","text":"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let textRange = Range(match.range(at: 1), in: line) else {
                return nil
            }
            return decodeJSONStringLiteral(String(line[textRange]))
        }
    }

    private static func decodeJSONStringLiteral(_ rawValue: String) -> String? {
        let literal = "\"\(rawValue)\""
        guard let data = literal.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? String else {
            return nil
        }
        return value
    }

    private static func conversationText(from item: [String: Any]) -> String? {
        if let text = item["text"] as? String {
            return text
        }
        if let text = item["message"] as? String {
            return text
        }
        if let content = item["content"] as? String {
            return content
        }
        if let content = item["content"] as? [[String: Any]] {
            return content
                .compactMap { fragment in
                    let type = fragment["type"] as? String
                    guard type != "input_image" else { return nil }
                    return fragment["text"] as? String
                        ?? fragment["content"] as? String
                        ?? fragment["input_text"] as? String
                        ?? fragment["output_text"] as? String
                }
                .joined(separator: "\n")
        }
        return nil
    }

    private static func sanitizeConversationText(_ text: String) -> String {
        let redactedImageText = text
            .replacingOccurrences(of: "<image>", with: "")
            .replacingOccurrences(of: "</image>", with: "")
        let collapsed = redactedImageText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 420
        if collapsed.count > maxLength {
            return String(collapsed.prefix(maxLength - 1)) + "..."
        }
        return collapsed
    }

    private static func runSQLite(databaseURL: URL, query: String) -> String {
        runProcess(
            executable: "/usr/bin/sqlite3",
            arguments: ["-separator", "\u{1f}", databaseURL.path, query]
        )
    }

    private static func recentRolloutLines(from url: URL, limit: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer {
            try? handle.close()
        }

        let byteLimit: UInt64 = 8 * 1024 * 1024
        let endOffset = (try? handle.seekToEnd()) ?? 0
        let startOffset = endOffset > byteLimit ? endOffset - byteLimit : 0
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return []
        }

        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return []
        }

        var text = String(decoding: data, as: UTF8.self)
        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }

        return text
            .split(separator: "\n")
            .suffix(limit)
            .map(String.init)
    }

    private static func hasColumn(_ column: String, in table: String, databaseURL: URL) -> Bool {
        let output = runSQLite(databaseURL: databaseURL, query: "pragma table_info(\(table));")
        return output
            .split(separator: "\n")
            .contains { line in
                line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                    .dropFirst()
                    .first
                    .map(String.init) == column
            }
    }

    private static func runProcess(executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }
        if let date = iso8601WithFractionalSeconds.date(from: string) {
            return date
        }
        return iso8601.date(from: string)
    }

    private static func friendlyToolName(_ name: String) -> String {
        switch name {
        case "exec_command":
            return "Shell"
        case "apply_patch":
            return "Edit"
        case "spawn_agent", "wait_agent":
            return "Agent"
        case "web.run":
            return "Web"
        default:
            return name
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private static func commandSummary(from arguments: Any?) -> String? {
        guard let arguments = arguments as? String,
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["cmd"] as? String else {
            return nil
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.count > 72 {
            return String(trimmed.prefix(69)) + "..."
        }
        return trimmed
    }

    private static func usedPercent(in value: Any?) -> Double? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        if let number = dictionary["used_percent"] as? NSNumber {
            return number.doubleValue
        }
        if let number = dictionary["used_percent"] as? Double {
            return number
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func relativeAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "just now"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        return "\(minutes / 60)h ago"
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}
