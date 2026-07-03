import AppKit
import Defaults
import Foundation

final class VSCodeRecentProjectsService: ObservableObject {
    static let shared = VSCodeRecentProjectsService()

    @Published private(set) var projects: [VSCodeProjectItem] = []

    private let storageJSONURL: URL
    private let stateDatabaseURL: URL

    init(
        storageJSONURL: URL = VSCodeRecentProjectsService.defaultStorageJSONURL(),
        stateDatabaseURL: URL = VSCodeRecentProjectsService.defaultStateDatabaseURL()
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

    func refresh(includeMissing: Bool = false) {
        // Recursive filesystem walk + mtime sort can stall the main thread on
        // large home directories. Run it on a userInitiated queue and publish
        // the result back to main when ready.
        let directory = Self.effectiveProjectsDirectoryURL()
        let pinned = Defaults[.vscodePinnedFolders]
        let recentlyOpened = localFolderURLsFromStateDatabase()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var loaded = self.loadProjects(from: directory, includeMissing: includeMissing, limit: .max)
            var seen = Set(loaded.map { $0.id })

            // 独立文件夹：直接作为项目列入，不参与深度扫描
            for url in pinned {
                let standardized = url.standardizedFileURL
                guard seen.insert(standardized.path).inserted else { continue }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) && isDirectory.boolValue
                guard includeMissing || exists else { continue }
                loaded.append(VSCodeProjectItem(url: standardized, exists: exists))
            }

            // 匹配最近打开的文件夹，设置 lastSeenAt
            let now = Date()
            for (index, item) in loaded.enumerated() {
                if recentlyOpened.contains(where: { $0.path == item.url.path }) {
                    loaded[index] = VSCodeProjectItem(url: item.url, lastSeenAt: now, exists: item.exists)
                }
            }

            loaded.sort { lhs, rhs in
                let lhDate = lhs.lastSeenAt ?? .distantPast
                let rhDate = rhs.lastSeenAt ?? .distantPast
                return lhDate > rhDate
            }
            DispatchQueue.main.async {
                self.projects = loaded
            }
        }
    }

    func loadProjects(from directory: URL, includeMissing: Bool, limit: Int) -> [VSCodeProjectItem] {
        let urls = localProjectsFromDirectory(directory)
        var seen = Set<String>()
        var items: [VSCodeProjectItem] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard seen.insert(path).inserted else { continue }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            guard includeMissing || exists else { continue }

            items.append(VSCodeProjectItem(url: standardized, exists: exists))
            if items.count >= limit {
                break
            }
        }

        return items
    }

    func open(_ item: VSCodeProjectItem) {
        AppLauncherService.openVSCodeProject(item.url)
        // 更新 lastSeenAt，使其排在最前面
        let now = Date()
        projects = projects.map { existing in
            existing.id == item.id 
                ? VSCodeProjectItem(url: item.url, lastSeenAt: now, exists: item.exists)
                : existing
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
}
