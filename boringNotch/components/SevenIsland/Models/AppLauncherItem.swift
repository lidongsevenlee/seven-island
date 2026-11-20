import Foundation

struct AppLauncherItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case app
        case jar
    }

    let url: URL
    let name: String
    let kind: Kind

    var id: String { url.path }
    var detail: String { url.deletingLastPathComponent().path }

    func matches(query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || url.lastPathComponent.localizedCaseInsensitiveContains(query)
            || detail.localizedCaseInsensitiveContains(query)
    }
}
