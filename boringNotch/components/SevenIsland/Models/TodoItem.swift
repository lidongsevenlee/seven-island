import Defaults
import Foundation

struct TodoItem: Codable, Defaults.Serializable, Equatable, Identifiable {
    let id: UUID
    var text: String
    let createdAt: Date
    var completedAt: Date?

    var isCompleted: Bool { completedAt != nil }
}

enum TodoFilter: Hashable {
    case today
    case all
    case day(Date)
}

struct TodoSection: Identifiable {
    enum ID: Hashable {
        case today
        case day(Date)
    }

    let id: ID
    let items: [TodoItem]
}
