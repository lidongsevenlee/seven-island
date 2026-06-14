//
//  HooksActivityModels.swift
//  boringNotch
//
//  Claude Code hooks activity — session-level data models.
//

import Foundation

// MARK: - HookEvent

/// A single hook notification event persisted to hooks-log.jsonl
struct HookEvent: Identifiable, Codable {
    var id: UUID = UUID()
    let ts: Double
    let event: String
    let sessionId: String
    let cwd: String
    let toolName: String?
    let summary: String?
    let model: String?           // populated on SessionStart
    let parentSessionId: String? // non-nil means this is a sub-agent session

    enum CodingKeys: String, CodingKey {
        case ts, event
        case sessionId = "session_id"
        case cwd
        case toolName = "tool_name"
        case summary, model
        case parentSessionId = "parent_session_id"
    }
}

// MARK: - SessionStatus

/// Lifecycle state derived from hook event stream (mirrors herdr-agent-state.sh)
enum SessionStatus {
    case idle    // SessionStart or after Stop — waiting for next user prompt
    case working // PreToolUse / UserPromptSubmit — actively processing
    case blocked // PermissionRequest — waiting for user to grant permission
    case ended   // SessionEnd — session is fully terminated
}

extension SessionStatus {
    var label: String {
        switch self {
        case .idle:    return "空闲"
        case .working: return "进行中"
        case .blocked: return "等待授权"
        case .ended:   return "已结束"
        }
    }

    /// Whether the session is still alive (not ended)
    var isLive: Bool { self != .ended }
}

// MARK: - HookSession

/// A Claude Code session reconstructed from the event log
struct HookSession: Identifiable {
    let id: String              // session_id
    let cwd: String             // from SessionStart or first event
    var model: String?          // from SessionStart (may arrive later)
    let startTs: Double         // SessionStart.ts
    var endTs: Double?          // SessionEnd.ts
    var status: SessionStatus
    var lastUserPrompt: String?        // most recent UserPromptSubmit.summary
    var lastAssistantMessage: String?  // most recent Stop.summary
    var notableEvents: [HookEvent]     // PermissionRequest / Notification / StopFailure

    // MARK: Computed

    var cwdBasename: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var durationLabel: String {
        let total = Int((endTs ?? Date().timeIntervalSince1970) - startTs)
        if total < 0 { return "—" }
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let h = total / 3600
        let m = (total % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    var modelShort: String {
        guard let m = model else { return "—" }
        // Strip common prefixes for display: "claude-opus-4-8" → "Opus 4.8"
        let cleaned = m
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "auto-std", with: "Auto")
            .replacingOccurrences(of: "auto-", with: "")
        return cleaned.isEmpty ? m : cleaned
    }
}
