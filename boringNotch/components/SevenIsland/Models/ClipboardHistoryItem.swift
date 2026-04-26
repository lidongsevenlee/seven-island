import Foundation

struct ClipboardHistoryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), content: String, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }

    var preview: String {
        content.replacingOccurrences(of: "\n", with: " ")
    }
}
