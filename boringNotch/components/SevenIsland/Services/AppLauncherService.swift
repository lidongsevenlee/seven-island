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
