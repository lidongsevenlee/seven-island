import AppKit
import Foundation

enum AppLauncherService {
    static func openVSCodeProject(_ url: URL) {
        if runCodeCLI(arguments: ["-n", url.path]) {
            return
        }

        let appURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            return
        }

        NSWorkspace.shared.open(url)
    }

    static func openCodexApp() {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }

        if let codexURL = URL(string: "codex://") {
            NSWorkspace.shared.open(codexURL)
        }
    }

    static func openCodexSession(id: String) {
        if let sessionURL = codexSessionURL(for: id),
           NSWorkspace.shared.open(sessionURL) {
            return
        }

        openCodexApp()
    }

    static func openClaudeSession(id: String, cwd: String?) {
        let appURL = URL(fileURLWithPath: "/Applications/Claude.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return
        }

        if let claudeURL = URL(string: "claude://") {
            NSWorkspace.shared.open(claudeURL)
        }
    }

    static func codexSessionURL(for id: String) -> URL? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCodexConversationID(trimmedID) else {
            return nil
        }

        return URL(string: "codex://threads/\(trimmedID)")
    }

    private static func isCodexConversationID(_ id: String) -> Bool {
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    private static func runCodeCLI(arguments: [String]) -> Bool {
        let candidates = [
            "/opt/homebrew/bin/code",
            "/usr/local/bin/code"
        ]

        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
