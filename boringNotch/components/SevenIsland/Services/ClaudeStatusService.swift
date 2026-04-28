import Foundation

final class ClaudeStatusService: ObservableObject {
    static let shared = ClaudeStatusService()

    @Published private(set) var snapshot: ClaudeStatusSnapshot = .empty

    private let claudeDirectory: URL
    private let currentWorkspacePath: String
    private var isRefreshing = false

    init(
        claudeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
        currentWorkspacePath: String = FileManager.default.currentDirectoryPath
    ) {
        self.claudeDirectory = claudeDirectory
        self.currentWorkspacePath = currentWorkspacePath
    }

    func openClaude(session: ClaudeSessionSummary) {
        AppLauncherService.openClaudeSession(id: session.id, cwd: session.cwd)
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let claudeDir = claudeDirectory
        let workspacePath = currentWorkspacePath

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Self.loadSnapshot(
                claudeDirectory: claudeDir,
                currentWorkspacePath: workspacePath
            )

            DispatchQueue.main.async {
                self?.snapshot = snapshot
                self?.isRefreshing = false
            }
        }
    }

    private static func loadSnapshot(claudeDirectory: URL, currentWorkspacePath: String) -> ClaudeStatusSnapshot {
        let sessionsDir = claudeDirectory.appendingPathComponent("sessions")
        let projectsDir = claudeDirectory.appendingPathComponent("projects")

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return .empty
        }

        guard let sessionFiles = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else {
            return .empty
        }

        let sessions: [ClaudeSessionSummary] = sessionFiles
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                loadSession(from: url, projectsDir: projectsDir)
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        let preferred = preferCurrentWorkspaceSessions(sessions, currentWorkspacePath: currentWorkspacePath)

        return ClaudeStatusSnapshot(recentSessions: preferred)
    }

    private static func loadSession(from url: URL, projectsDir: URL) -> ClaudeSessionSummary? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let sessionId = json["sessionId"] as? String else {
            return nil
        }

        let title = json["title"] as? String
        let cwd = json["cwd"] as? String ?? ""
        let model = json["model"] as? String
        var startedAt = Date()

        // startedAt is a Unix timestamp in milliseconds (e.g. 1777210178393)
        if let startedAtMillis = json["startedAt"] as? Int {
            startedAt = Date(timeIntervalSince1970: Double(startedAtMillis) / 1000.0)
        }

        let encodedCwd = encodeCWD(cwd)
        let jsonlURL = projectsDir
            .appendingPathComponent(encodedCwd, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")

        let lines: [String] = {
            guard FileManager.default.fileExists(atPath: jsonlURL.path),
                  let handle = try? FileHandle(forReadingFrom: jsonlURL) else {
                return []
            }
            defer { try? handle.close() }

            let byteLimit: UInt64 = 4 * 1024 * 1024
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
                .suffix(100)
                .map(String.init)
        }()

        let activity = lines.isEmpty ? nil : activity(fromJSONLLines: lines, sessionUpdatedAt: startedAt)
        let lastTurn = lines.isEmpty ? nil : lastConversationTurn(from: lines)
        let slug = loadSlug(from: jsonlURL)

        let resolvedModel = model ?? loadModel(from: jsonlURL)

        // Use the slug as title if no title in session file, fallback to first user prompt
        let resolvedTitle: String = {
            if let t = title, !t.isEmpty { return t }
            if let s = slug {
                return s.replacingOccurrences(of: "-", with: " ").capitalized
            }
            if let firstPrompt = firstUserPrompt(from: lines) {
                let trimmed = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                // Limit to a reasonable title length
                if trimmed.count > 72 {
                    return String(trimmed.prefix(69)) + "..."
                }
                return trimmed
            }
            return "Claude session"
        }()

        return ClaudeSessionSummary(
            id: sessionId,
            title: resolvedTitle,
            cwd: cwd,
            updatedAt: activity?.updatedAt ?? startedAt,
            model: resolvedModel,
            activity: activity,
            lastTurn: lastTurn,
            slug: slug
        )
    }

    private static func loadModel(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let firstLine = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: true).first,
              let json = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any] else {
            return nil
        }
        let msg = json["message"] as? [String: Any]
        return msg?["model"] as? String
    }

    private static func loadSlug(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let firstLine = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: true).first,
              let json = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any] else {
            return nil
        }
        return json["slug"] as? String
    }

    private static func activity(
        fromJSONLLines lines: [String],
        sessionUpdatedAt: Date,
        now: Date = Date()
    ) -> ClaudeWorkActivity {
        var latestTimestamp = sessionUpdatedAt
        var lastToolName: String?
        var headline: String?
        var detail: String?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let timestamp = parseTimestamp(json["timestamp"] as? String) {
                latestTimestamp = max(latestTimestamp, timestamp)
            }

            let msg = json["message"] as? [String: Any]
            let content = msg?["content"] as? [[String: Any]] ?? json["content"] as? [[String: Any]]
            let role = msg?["role"] as? String ?? json["role"] as? String
            let lineType = json["type"] as? String

            // Look for tool_use blocks inside message.content[]
            var foundToolUse = false
            if let blocks = content {
                for block in blocks {
                    let blockType = block["type"] as? String
                    if blockType == "tool_use" || blockType == "function" {
                        foundToolUse = true
                        let name = block["name"] as? String ?? "tool"
                        lastToolName = friendlyToolName(name)
                        headline = "Using \(lastToolName!)"
                        detail = "\(lastToolName!)"

                        // Try to extract the command from tool input
                        if let input = block["input"] as? [String: Any] {
                            let commandSummary = input["command"] as? String
                                ?? input["cmd"] as? String
                                ?? (input["arguments"] as? [String: Any])?["command"] as? String
                                ?? (input["arguments"] as? [String: Any])?["cmd"] as? String
                            if let cmd = commandSummary, !cmd.isEmpty {
                                let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                                headline = trimmed.count > 72 ? String(trimmed.prefix(69)) + "..." : trimmed
                                detail = "\(lastToolName!): \(headline!)"
                            }
                        }
                    }
                }
            }

            // Fallback: user text for headline/detail
            if !foundToolUse, lineType == "user" || role == "user" {
                if let blocks = content {
                    for block in blocks {
                        if let text = block["text"] as? String, !text.isEmpty {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            headline = "Processing user request"
                            detail = trimmed.count > 80 ? String(trimmed.prefix(77)) + "..." : trimmed
                        }
                    }
                }
            }

            // Fallback: assistant text when no tool
            if !foundToolUse, lineType == "assistant" || role == "assistant" {
                if let blocks = content {
                    for block in blocks {
                        if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                            if lastToolName == nil {
                                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                headline = "Responding"
                                detail = clean.count > 80 ? String(clean.prefix(77)) + "..." : clean
                            }
                        }
                    }
                }
            }
        }

        let isRecent = now.timeIntervalSince(latestTimestamp) <= 30
        let state: ClaudeWorkState = isRecent ? .working : .idle
        let fallbackHeadline = isRecent ? "Claude is working" : "Claude is idle"

        let pending = pendingAction(fromLines: lines, now: now)

        return ClaudeWorkActivity(
            state: state,
            headline: headline ?? fallbackHeadline,
            detail: detail ?? "Last activity \(relativeAge(from: latestTimestamp, to: now))",
            lastToolName: lastToolName,
            updatedAt: latestTimestamp,
            pendingAction: pending
        )
    }

    private static func firstUserPrompt(from lines: [String]) -> String? {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let lineType = json["type"] as? String
            let msg = json["message"] as? [String: Any]
            let role = msg?["role"] as? String ?? json["role"] as? String
            let content = msg?["content"] as? [[String: Any]] ?? json["content"] as? [[String: Any]]

            if lineType == "user" || role == "user" {
                let text = content?.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: " ") ?? ""
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    static func lastConversationTurn(from lines: [String]) -> ClaudeConversationTurn? {
        var currentUserText: String?
        var currentAssistantText: String?
        var lastTurn: ClaudeConversationTurn?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let lineType = json["type"] as? String
            let msg = json["message"] as? [String: Any]
            let role = msg?["role"] as? String ?? json["role"] as? String
            let content = msg?["content"] as? [[String: Any]] ?? json["content"] as? [[String: Any]]

            if lineType == "user" || role == "user" {
                let text = content?.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n") ?? ""
                let clean = sanitizeText(text)
                if !clean.isEmpty {
                    currentUserText = clean
                    currentAssistantText = nil
                    lastTurn = ClaudeConversationTurn(userText: currentUserText, assistantText: nil)
                }
            } else if lineType == "assistant" || role == "assistant" {
                let text = content?.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n") ?? ""
                let clean = sanitizeText(text)
                if !clean.isEmpty {
                    currentAssistantText = clean
                    if currentUserText != nil || currentAssistantText != nil {
                        lastTurn = ClaudeConversationTurn(
                            userText: currentUserText,
                            assistantText: currentAssistantText
                        )
                    }
                }
            }
        }

        return lastTurn?.hasContent == true ? lastTurn : nil
    }

    private static func sanitizeText(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 420
        if collapsed.count > maxLength {
            return String(collapsed.prefix(maxLength - 1)) + "..."
        }
        return collapsed
    }

    private static func preferCurrentWorkspaceSessions(
        _ sessions: [ClaudeSessionSummary],
        currentWorkspacePath: String
    ) -> [ClaudeSessionSummary] {
        let current = sessions.filter { $0.cwd == currentWorkspacePath }
        if current.isEmpty {
            return Array(sessions.prefix(10))
        }
        return Array((current + sessions.filter { $0.cwd != currentWorkspacePath }).prefix(10))
    }

    private static func encodeCWD(_ cwd: String) -> String {
        // Claude Code replaces "/" with "-" and drops the leading "/"
        // e.g. "/Users/didi/project" → "-Users-didi-project"
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    private static func recentJSONLLines(from url: URL, limit: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        let byteLimit: UInt64 = 4 * 1024 * 1024
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

    private static func friendlyToolName(_ name: String) -> String {
        switch name {
        case "exec_command", "Bash", "bash":
            return "Shell"
        case "apply_patch", "Edit", "edit":
            return "Edit"
        case "Read", "read":
            return "Read"
        case "Write", "write":
            return "Write"
        case "spawn_agent", "wait_agent", "Agent":
            return "Agent"
        case "WebSearch", "web_search", "WebFetch", "web_fetch", "Web", "web":
            return "Web"
        case "Browser", "browser":
            return "Browser"
        default:
            return name
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private static func pendingAction(fromLines lines: [String], now: Date) -> ClaudePendingAction? {
        // Scan from end to find the last assistant tool_use
        var lastToolName: String?
        var lastToolCommand: String?
        var lastToolTimestamp: Date?
        var foundUserAfter = false

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let lineType = json["type"] as? String
            let msg = json["message"] as? [String: Any]
            let role = msg?["role"] as? String ?? json["role"] as? String
            let content = msg?["content"] as? [[String: Any]] ?? json["content"] as? [[String: Any]]

            // If we found a user message after the last tool_use, it's not pending
            if lineType == "user" || role == "user" {
                foundUserAfter = true
            }

            // Look for assistant tool_use
            if !foundUserAfter && (lineType == "assistant" || role == "assistant") {
                if let blocks = content as? [[String: Any]] {
                    for block in blocks {
                        let blockType = block["type"] as? String
                        if blockType == "tool_use" || blockType == "function" {
                            let name = block["name"] as? String ?? "tool"
                            lastToolName = friendlyToolName(name)
                            lastToolTimestamp = parseTimestamp(json["timestamp"] as? String)
                            if let input = block["input"] as? [String: Any] {
                                lastToolCommand = input["command"] as? String
                                    ?? input["cmd"] as? String
                                    ?? (input["arguments"] as? [String: Any])?["command"] as? String
                            }
                        }
                    }
                }
            }

            // Stop if we found a tool_use and then a user message
            if lastToolName != nil && foundUserAfter {
                break
            }
        }

        guard let toolName = lastToolName,
              let timestamp = lastToolTimestamp,
              !foundUserAfter,
              now.timeIntervalSince(timestamp) <= 30 else {
            return nil
        }

        let confirmTools: Set<String> = ["Shell", "Bash", "Edit", "Write", "Web", "Browser", "Agent"]
        guard confirmTools.contains(toolName) else { return nil }

        return ClaudePendingAction(
            toolName: toolName,
            command: lastToolCommand,
            timestamp: timestamp
        )
    }

    private static func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = iso8601WithFractionalSeconds.date(from: string) {
            return date
        }
        return iso8601.date(from: string)
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
