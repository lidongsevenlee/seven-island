import Foundation

struct ClipboardHistoryItem: Codable, Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case text = "文本"
        case image = "图片"
        case files = "文件"
    }

    let id: UUID
    let createdAt: Date
    let content: String?
    let imageData: Data?
    let fileURLs: [URL]?

    init(content: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.content = content
        self.imageData = nil
        self.fileURLs = nil
    }

    init(imageData: Data) {
        self.id = UUID()
        self.createdAt = Date()
        self.content = nil
        self.imageData = imageData
        self.fileURLs = nil
    }

    init(fileURLs: [URL]) {
        self.id = UUID()
        self.createdAt = Date()
        self.content = nil
        self.imageData = nil
        self.fileURLs = fileURLs
    }

    var kind: Kind {
        if fileURLs?.isEmpty == false { return .files }
        if imageData != nil { return .image }
        return .text
    }

    var isImage: Bool { kind == .image }

    var preview: String {
        if let text = content {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        if let fileURLs, !fileURLs.isEmpty {
            return fileURLs.map(\.lastPathComponent).joined(separator: "、")
        }
        return "[Image]"
    }

    func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        switch kind {
        case .text:
            return content?.localizedCaseInsensitiveContains(query) == true
        case .image:
            return false
        case .files:
            return fileURLs?.contains { $0.path.localizedCaseInsensitiveContains(query) } == true
        }
    }
}
