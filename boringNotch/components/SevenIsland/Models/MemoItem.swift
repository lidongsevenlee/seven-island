import Defaults
import Foundation

struct MemoItem: Codable, Equatable, Identifiable {
    let id: UUID
    let number: Int
    var text: String

    init(id: UUID = UUID(), number: Int, text: String = "") {
        self.id = id
        self.number = number
        self.text = text
    }

    var title: String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine.map { String($0.prefix(40)) } ?? "备忘录\(number)"
    }
}

struct MemoLibrary: Codable, Equatable, Defaults.Serializable {
    var items: [MemoItem]
    var selectedID: UUID?
    var nextNumber: Int
}
