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
        projects = loadProjects(from: Self.effectiveProjectsDirectoryURL(), includeMissing: includeMissing, limit: .max)
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
    }

    private func localProjectsFromDirectory(_ dir: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        .sorted { lhs, rhs in
            let lhDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhDate > rhDate
        } ?? []
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
