import Foundation

struct AppLauncherItem: Equatable, Identifiable, Sendable {
    let url: URL
    let name: String

    var id: String { url.path }
    var detail: String { url.deletingLastPathComponent().path }

    func matches(query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query)
            || detail.localizedCaseInsensitiveContains(query)
    }
}
