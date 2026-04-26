import Foundation

struct VSCodeProjectItem: Equatable, Identifiable {
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
