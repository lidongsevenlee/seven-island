import AppKit
import Foundation

enum AppLauncherService {
    static let defaultApplicationDirectories = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true)
    ]

    static func applicationDirectories(adding extraDirectories: [URL]) -> [URL] {
        var paths = Set<String>()
        return (defaultApplicationDirectories + extraDirectories)
            .filter(\.isFileURL)
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { paths.insert($0.path).inserted }
    }

    static func loadApplications(from directories: [URL]) -> [AppLauncherItem] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var applications: [AppLauncherItem] = []

        for directory in directories {
            guard !Task.isCancelled else { return [] }
            guard let entries = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let entry as URL in entries {
                guard !Task.isCancelled else { return [] }
                guard entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                entries.skipDescendants()
                let url = entry.standardizedFileURL.resolvingSymlinksInPath()
                guard seen.insert(url.path).inserted,
                      let bundle = Bundle(url: url),
                      let executable = bundle.executableURL,
                      fileManager.isExecutableFile(atPath: executable.path) else { continue }

                let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
                applications.append(AppLauncherItem(url: url, name: name))
            }
        }

        return applications.sorted {
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.id < $1.id : byName == .orderedAscending
        }
    }

    @MainActor
    static func openApplication(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

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
