import AppKit
import Foundation

enum AppLauncherService {
    enum JavaLaunchError: LocalizedError {
        case runtimeUnavailable
        case archiveUnavailable
        case exited(Int32)

        var errorDescription: String? {
            switch self {
            case .runtimeUnavailable: "未找到 Java 运行环境。运行 JAR 需要兼容的 Java。"
            case .archiveUnavailable: "无法读取 JAR 文件。"
            case .exited(let status): "Java 启动失败（退出码 \(status)）。请检查 JAR 的启动入口和 Java 版本。"
            }
        }
    }

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
                guard let kind = AppLauncherItem.Kind(rawValue: entry.pathExtension.lowercased()) else { continue }
                if kind == .app { entries.skipDescendants() }
                let url = entry.standardizedFileURL.resolvingSymlinksInPath()
                guard !seen.contains(url.path) else { continue }
                let name: String
                switch kind {
                case .app:
                    guard let bundle = Bundle(url: url),
                          let executable = bundle.executableURL,
                          fileManager.isExecutableFile(atPath: executable.path) else { continue }
                    let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
                case .jar:
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    name = url.lastPathComponent
                }
                seen.insert(url.path)
                applications.append(AppLauncherItem(url: url, name: name, kind: kind))
            }
        }

        return applications.sorted {
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.id < $1.id : byName == .orderedAscending
        }
    }

    @MainActor
    static func openApplication(_ item: AppLauncherItem) async throws {
        switch item.kind {
        case .app:
            let configuration = NSWorkspace.OpenConfiguration()
            _ = try await NSWorkspace.shared.openApplication(at: item.url, configuration: configuration)
        case .jar:
            try await openJavaArchive(item.url)
        }
    }

    private static func openJavaArchive(_ archive: URL) async throws {
        guard (try? archive.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: archive.path) else {
            throw JavaLaunchError.archiveUnavailable
        }
        let java = await Task.detached(priority: .userInitiated) { javaExecutable() }.value
        try Task.checkCancellation()
        guard let java else { throw JavaLaunchError.runtimeUnavailable }
        let process = Process()
        process.executableURL = java
        process.arguments = ["-jar", archive.path]
        process.currentDirectoryURL = archive.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(for: .milliseconds(600))
        if !process.isRunning, process.terminationStatus != 0 {
            throw JavaLaunchError.exited(process.terminationStatus)
        }
    }

    private static func javaExecutable() -> URL? {
        let files = FileManager.default
        func executable(in home: String) -> URL? {
            guard home.hasPrefix("/") else { return nil }
            let java = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("bin/java")
            return files.isExecutableFile(atPath: java.path) ? java : nil
        }

        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"], let java = executable(in: home) {
            return java
        }
        if let home = registeredJavaHome(), let java = executable(in: home) {
            return java
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let opt = URL(fileURLWithPath: prefix, isDirectory: true).appendingPathComponent("opt")
            let versionedJDKs = (try? files.contentsOfDirectory(atPath: opt.path))?
                .filter { $0.hasPrefix("openjdk@") }
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending } ?? []
            for name in ["openjdk"] + versionedJDKs {
                if let java = executable(in: opt.appendingPathComponent(name).path) { return java }
            }
        }
        return nil
    }

    private static func registeredJavaHome() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        process.arguments = ["-F"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var hasVSCodeCLI: Bool { vsCodeCLI != nil }

    private static var vsCodeCLI: String? {
        let candidates = [
            "/opt/homebrew/bin/code",
            "/usr/local/bin/code"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func launchVSCodeCLI(for directory: URL) -> Bool {
        guard let executable = vsCodeCLI else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-n", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
