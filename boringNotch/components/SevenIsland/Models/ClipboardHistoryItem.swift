import Foundation

struct ClipboardHistoryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let content: String?
    let imageData: Data?

    init(content: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.content = content
        self.imageData = nil
    }

    init(imageData: Data) {
        self.id = UUID()
        self.createdAt = Date()
        self.content = nil
        self.imageData = imageData
    }

    var isImage: Bool { imageData != nil }

    var preview: String {
        if let text = content {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        return "[Image]"
    }
}
