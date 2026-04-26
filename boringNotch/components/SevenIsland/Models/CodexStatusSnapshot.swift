import Foundation

struct CodexSessionSummary: Equatable, Identifiable {
    let id: String
    let title: String
    let cwd: String
    let updatedAt: Date
    let tokensUsed: Int
    let model: String?
    let reasoningEffort: String?
    let rolloutPath: String?
    let activity: CodexWorkActivity?
    let lastTurn: CodexConversationTurn?

    var tokensDisplayText: String {
        Self.numberFormatter.string(from: NSNumber(value: tokensUsed)) ?? "\(tokensUsed)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

struct CodexConversationTurn: Equatable {
    let userText: String?
    let assistantText: String?

    var hasContent: Bool {
        userText?.isEmpty == false || assistantText?.isEmpty == false
    }
}

enum CodexWorkState: String, Equatable {
    case working = "Working"
    case idle = "Idle"
}

struct CodexWorkActivity: Equatable {
    let state: CodexWorkState
    let headline: String
    let detail: String
    let lastToolName: String?
    let updatedAt: Date
    let primaryLimitUsedPercent: Double?
    let secondaryLimitUsedPercent: Double?
    let creditsBalance: String?
    let hasCredits: Bool?
    let planType: String?

    var stateDisplayText: String {
        state.rawValue
    }

    var primaryLimitDisplayText: String {
        Self.percentFormatter(primaryLimitUsedPercent)
    }

    var secondaryLimitDisplayText: String {
        Self.percentFormatter(secondaryLimitUsedPercent)
    }

    var creditsDisplayText: String {
        if let creditsBalance {
            return "Credits \(creditsBalance)"
        }
        if hasCredits == false {
            return "No credits"
        }
        return "Open Codex"
    }

    var planDisplayText: String {
        planType?.capitalized ?? "Plan unknown"
    }

    private static func percentFormatter(_ value: Double?) -> String {
        guard let value else {
            return "Unknown"
        }
        return "\(Int(value.rounded()))%"
    }
}

struct CodexStatusSnapshot: Equatable {
    let recentSessions: [CodexSessionSummary]
    let totalThreads: Int
    let totalTokensUsed: Int
    let codexCLIStatus: String
    let codexAppVersion: String?
    let isAuthFilePresent: Bool
    let isDeviceBindingPresent: Bool

    var currentActivity: CodexWorkActivity? {
        recentSessions.first?.activity
    }

    var shouldShowClosedLiveActivity: Bool {
        currentActivity?.state == .working
    }

    var quotaDisplayText: String {
        if let activity = currentActivity {
            if let primary = activity.primaryLimitUsedPercent {
                return "Limit \(Int(primary.rounded()))%"
            }
            if let credits = activity.creditsBalance {
                return "Credits \(credits)"
            }
        }
        return "Open Codex"
    }

    var totalTokensDisplayText: String {
        let formatted = Self.numberFormatter.string(from: NSNumber(value: totalTokensUsed)) ?? "\(totalTokensUsed)"
        return "\(formatted) tokens"
    }

    var authorizationDisplayText: String {
        if isAuthFilePresent {
            return "Auth file present"
        }
        return "Not signed in locally"
    }

    static let empty = CodexStatusSnapshot(
        recentSessions: [],
        totalThreads: 0,
        totalTokensUsed: 0,
        codexCLIStatus: "Codex CLI not found",
        codexAppVersion: nil,
        isAuthFilePresent: false,
        isDeviceBindingPresent: false
    )

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
