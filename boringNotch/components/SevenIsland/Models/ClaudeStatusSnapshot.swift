import Foundation

struct ClaudeSessionSummary: Equatable, Identifiable {
    let id: String
    let title: String
    let cwd: String
    let updatedAt: Date
    let model: String?
    let activity: ClaudeWorkActivity?
    let lastTurn: ClaudeConversationTurn?
    let slug: String?
}

struct ClaudeConversationTurn: Equatable {
    let userText: String?
    let assistantText: String?

    var hasContent: Bool {
        userText?.isEmpty == false || assistantText?.isEmpty == false
    }
}

enum ClaudeWorkState: String, Equatable {
    case working = "Working"
    case idle = "Idle"
}

struct ClaudeWorkActivity: Equatable {
    let state: ClaudeWorkState
    let headline: String
    let detail: String
    let lastToolName: String?
    let updatedAt: Date
    let pendingAction: ClaudePendingAction?
}

struct ClaudePendingAction: Equatable {
    let toolName: String
    let command: String?
    let timestamp: Date
}

struct ClaudeStatusSnapshot: Equatable {
    let recentSessions: [ClaudeSessionSummary]

    var currentActivity: ClaudeWorkActivity? {
        recentSessions.first?.activity
    }

    var shouldShowClosedLiveActivity: Bool {
        currentActivity?.state == .working
    }

    var totalSessions: Int {
        recentSessions.count
    }

    static let empty = ClaudeStatusSnapshot(recentSessions: [])
}
