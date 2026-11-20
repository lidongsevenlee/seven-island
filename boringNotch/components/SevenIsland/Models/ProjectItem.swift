import Defaults
import Foundation

struct ProjectItem: Equatable, Identifiable {
    let id: String
    let url: URL
    let lastSeenAt: Date?
    let exists: Bool

    init(url: URL, lastSeenAt: Date? = nil, exists: Bool = true) {
        self.url = url
        self.lastSeenAt = lastSeenAt
        self.exists = exists
        self.id = url.standardizedFileURL.path
    }

    var name: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var detail: String {
        url.deletingLastPathComponent().path
    }

    func matches(query: String) -> Bool {
        name.lowercased().contains(query) || detail.lowercased().contains(query)
    }
}

struct ProjectOpenMethod: Identifiable, Equatable, Codable, Defaults.Serializable {
    enum Kind: String, CaseIterable, Codable, Identifiable {
        case folder, link, command

        var id: Self { self }
        var title: String {
            switch self {
            case .folder: "用应用打开文件夹"
            case .link: "URL 模板"
            case .command: "可执行文件和参数"
            }
        }
    }

    static let vscode = Self(id: "vscode", title: "VS Code", applicationBundleID: "com.microsoft.VSCode")
    static let codex = Self(
        id: "codex", title: "Codex", kind: .link, applicationBundleID: "com.openai.codex",
        linkTemplate: "codex://threads/new?path={path}"
    )
    static let presets = [vscode, codex]

    var id: String = UUID().uuidString
    var title = ""
    var kind: Kind = .folder
    var applicationURL: URL?
    var applicationBundleID: String?
    var linkTemplate = ""
    var executablePath = ""
    var argumentTemplate = "{path}"

    var hasApplication: Bool { applicationURL != nil || applicationBundleID != nil }

    var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .folder: return hasApplication
        case .link: return linkTemplate.contains("{path}") && link(for: URL(fileURLWithPath: "/tmp/项目")) != nil
        case .command:
            return (executablePath as NSString).expandingTildeInPath.hasPrefix("/")
                && argumentTemplate.contains("{path}")
        }
    }

    func link(for directory: URL) -> URL? {
        let queryValueCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedPath = directory.path.addingPercentEncoding(withAllowedCharacters: queryValueCharacters),
              let link = URL(string: linkTemplate.replacingOccurrences(of: "{path}", with: encodedPath)),
              link.scheme != nil else { return nil }
        return link
    }

    func arguments(for directory: URL) -> [String] {
        argumentTemplate.split(whereSeparator: \.isNewline).map {
            $0.replacingOccurrences(of: "{path}", with: directory.path)
        }
    }

    static func preferred(in methods: [Self], id: ID) -> Self? {
        methods.first { $0.id == id } ?? methods.first
    }

    static func forApplication(_ app: URL) -> Self {
        let bundle = Bundle(url: app)
        let identifier = bundle?.bundleIdentifier
        if var preset = presets.first(where: { $0.applicationBundleID == identifier }) {
            preset.applicationURL = app
            return preset
        }
        let title = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? app.deletingPathExtension().lastPathComponent
        return Self(title: title, applicationURL: app, applicationBundleID: identifier)
    }
}
