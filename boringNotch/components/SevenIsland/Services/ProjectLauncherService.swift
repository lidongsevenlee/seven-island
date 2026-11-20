import AppKit
import Defaults
import Foundation

final class ProjectLauncherService: ObservableObject {
    static let shared = ProjectLauncherService()

    @Published private(set) var projects: [ProjectItem] = []
    private var refreshGeneration = 0

    private let storageJSONURL: URL
    private let stateDatabaseURL: URL

    init(
        storageJSONURL: URL = ProjectLauncherService.defaultStorageJSONURL(),
        stateDatabaseURL: URL = ProjectLauncherService.defaultStateDatabaseURL()
    ) {
        self.storageJSONURL = storageJSONURL
        self.stateDatabaseURL = stateDatabaseURL
    }

    static func effectiveProjectsDirectoryURL() -> URL {
        let configured = Defaults[.vscodeProjectsDirectory]
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return defaultProjectsDirectoryURL()
    }

    @MainActor
    func refresh(includeMissing: Bool = false) {
        // Recursive filesystem walk + mtime sort can stall the main thread on
        // large home directories. Run it on a userInitiated queue and publish
        // the result back to main when ready.
        let directory = Self.effectiveProjectsDirectoryURL()
        let pinned = Defaults[.vscodePinnedFolders]
        refreshGeneration += 1
        let generation = refreshGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let recentlyOpened = Set(self.localFolderURLsFromStateDatabase().map(\.path))
            var loaded = self.loadProjects(from: directory, includeMissing: includeMissing, limit: .max)
            var seen = Set(loaded.map { $0.id })

            // 独立文件夹：直接作为项目列入，不参与深度扫描
            for url in pinned {
                let standardized = url.standardizedFileURL
                guard seen.insert(standardized.path).inserted else { continue }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) && isDirectory.boolValue
                guard includeMissing || exists else { continue }
                loaded.append(ProjectItem(url: standardized, exists: exists))
            }

            // 匹配最近打开的文件夹，设置 lastSeenAt
            let now = Date()
            for (index, item) in loaded.enumerated() {
                if recentlyOpened.contains(item.url.path) {
                    loaded[index] = ProjectItem(url: item.url, lastSeenAt: now, exists: item.exists)
                }
            }

            loaded.sort { lhs, rhs in
                let lhDate = lhs.lastSeenAt ?? .distantPast
                let rhDate = rhs.lastSeenAt ?? .distantPast
                return lhDate > rhDate
            }
            DispatchQueue.main.async {
                guard self.refreshGeneration == generation else { return }
                self.projects = loaded
            }
        }
    }

    func loadProjects(from directory: URL, includeMissing: Bool, limit: Int) -> [ProjectItem] {
        let urls = localProjectsFromDirectory(directory)
        var seen = Set<String>()
        var items: [ProjectItem] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard seen.insert(path).inserted else { continue }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            guard includeMissing || exists else { continue }

            items.append(ProjectItem(url: standardized, exists: exists))
            if items.count >= limit {
                break
            }
        }

        return items
    }

    @MainActor
    func open(_ item: ProjectItem, with method: ProjectOpenMethod) async throws {
        let directory = item.url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LaunchError.missingProject
        }
        guard method.isValid else { throw LaunchError.invalidConfiguration }

        switch method.kind {
        case .folder:
            if Self.usesVSCodeCLI(method), AppLauncherService.launchVSCodeCLI(for: directory) { break }
            let app = try Self.requireApplication(for: method)
            try await Self.open(directory, withApplicationAt: app)
        case .link:
            guard let link = method.link(for: directory) else { throw LaunchError.invalidConfiguration }
            if method.hasApplication {
                let app = try Self.requireApplication(for: method)
                try await Self.open(link, withApplicationAt: app)
            } else if !NSWorkspace.shared.open(link) {
                throw LaunchError.missingApplication(method.title)
            }
        case .command:
            try await Self.run(method, in: directory)
        }
        recordOpened(item)
    }

    @MainActor
    static func isAvailable(_ method: ProjectOpenMethod) -> Bool {
        guard method.isValid else { return false }
        switch method.kind {
        case .folder:
            return applicationURL(for: method) != nil || (usesVSCodeCLI(method) && AppLauncherService.hasVSCodeCLI)
        case .link:
            if method.hasApplication { return applicationURL(for: method) != nil }
            guard let link = method.link(for: URL(fileURLWithPath: "/tmp")) else { return false }
            return NSWorkspace.shared.urlForApplication(toOpen: link) != nil
        case .command:
            return FileManager.default.isExecutableFile(atPath: (method.executablePath as NSString).expandingTildeInPath)
        }
    }

    private static func usesVSCodeCLI(_ method: ProjectOpenMethod) -> Bool {
        method.applicationURL == nil && method.applicationBundleID == ProjectOpenMethod.vscode.applicationBundleID
    }

    @MainActor
    static func applicationURL(for method: ProjectOpenMethod) -> URL? {
        if let url = method.applicationURL, let executable = Bundle(url: url)?.executableURL,
           FileManager.default.isExecutableFile(atPath: executable.path) {
            return url
        }
        return method.applicationBundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    @MainActor
    static func applicationIcon(for method: ProjectOpenMethod) -> NSImage? {
        let workspace = NSWorkspace.shared
        if let app = applicationURL(for: method) {
            return workspace.icon(forFile: app.path)
        }
        if method.kind == .link, !method.hasApplication,
           let link = method.link(for: URL(fileURLWithPath: "/tmp")),
           let app = workspace.urlForApplication(toOpen: link) {
            return workspace.icon(forFile: app.path)
        }
        return nil
    }

    @MainActor
    private static func requireApplication(for method: ProjectOpenMethod) throws -> URL {
        guard let app = applicationURL(for: method) else { throw LaunchError.missingApplication(method.title) }
        return app
    }

    @MainActor
    private static func open(_ target: URL, withApplicationAt app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open([target], withApplicationAt: app, configuration: configuration)
    }

    private static func run(_ method: ProjectOpenMethod, in directory: URL) async throws {
        let executable = (method.executablePath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw LaunchError.missingApplication(method.title)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = method.arguments(for: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(for: .milliseconds(250))
        if !process.isRunning, process.terminationStatus != 0 {
            throw LaunchError.commandFailed(process.terminationStatus)
        }
    }

    private func recordOpened(_ item: ProjectItem) {
        guard let index = projects.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = projects
        updated.remove(at: index)
        updated.insert(ProjectItem(url: item.url, lastSeenAt: .now), at: 0)
        projects = updated
    }

    enum LaunchError: LocalizedError {
        case missingProject
        case missingApplication(String)
        case invalidConfiguration
        case commandFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .missingProject: "找不到项目文件夹。"
            case .missingApplication(let title): "找不到「\(title)」。"
            case .invalidConfiguration: "请在「设置 → 项目」检查打开方式。"
            case .commandFailed(let status): "启动命令退出（状态码 \(status)）。"
            }
        }
    }

    private func localProjectsFromDirectory(_ dir: URL) -> [URL] {
        let maxDepth = Defaults[.vscodeScanDepth]
        return collectProjects(from: dir, maxDepth: maxDepth)
            .sorted { lhs, rhs in
                let lhDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhDate > rhDate
            }
    }

    private func collectProjects(from directory: URL, maxDepth: Int, currentDepth: Int = 0) -> [URL] {
        guard currentDepth < maxDepth else { return [] }

        var options: FileManager.DirectoryEnumerationOptions = []
        if !Defaults[.vscodeIncludeHidden] {
            options.insert(.skipsHiddenFiles)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: options
        )) ?? []

        var result: [URL] = []
        for url in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if currentDepth < maxDepth - 1 {
                result.append(contentsOf: collectProjects(from: url, maxDepth: maxDepth, currentDepth: currentDepth + 1))
            }

            result.append(url)
        }
        return result
    }

    static func defaultStorageJSONURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
    }

    static func defaultStateDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/state.vscdb")
    }

    static func defaultProjectsDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects")
    }

    private func localFolderURLsFromStorageJSON() -> [URL] {
        guard let data = try? Data(contentsOf: storageJSONURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var uriStrings: [String] = []

        if let associations = object["profileAssociations"] as? [String: Any],
           let workspaces = associations["workspaces"] as? [String: Any] {
            uriStrings.append(contentsOf: workspaces.keys)
        }

        return uriStrings.compactMap(Self.localFileURL(fromURI:))
    }

    private func localFolderURLsFromStateDatabase() -> [URL] {
        guard stateDatabaseURL.isFileURL,
              FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return []
        }

        let query = "select value from ItemTable where key in ('history.recentlyOpenedPathsList', 'recently.opened');"
        let output = Self.runProcess(
            executable: "/usr/bin/sqlite3",
            arguments: [stateDatabaseURL.path, query]
        )

        return output
            .split(separator: "\n")
            .flatMap { Self.localFolderURLs(fromRecentlyOpenedJSON: String($0)) }
    }

    static func localFolderURLs(fromRecentlyOpenedJSON json: String) -> [URL] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry in
            if let folderURI = entry["folderUri"] as? String {
                return localFileURL(fromURI: folderURI)
            }
            if let fileURI = entry["fileUri"] as? String {
                return localFileURL(fromURI: fileURI)?.deletingLastPathComponent()
            }
            return nil
        }
    }

    static func localFileURL(fromURI uri: String) -> URL? {
        guard uri.hasPrefix("file://") else { return nil }
        return URL(string: uri)?.standardizedFileURL
    }

    private static func runProcess(executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
