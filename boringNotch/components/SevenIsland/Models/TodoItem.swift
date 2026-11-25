import Defaults
import Foundation

struct TodoItem: Codable, Defaults.Serializable, Equatable, Identifiable {
    let id: UUID
    var text: String
    let createdAt: Date
    var completedAt: Date?
    var sortIndex: Int? = nil

    var isCompleted: Bool { completedAt != nil }
}

enum TodoFilter: Hashable {
    case today
    case all
    case day(Date)
}

enum TodoDateGrouping: Hashable {
    case creation
    case completion

    func date(for item: TodoItem) -> Date? {
        switch self {
        case .creation: item.createdAt
        case .completion: item.completedAt
        }
    }
}

struct TodoListScope: Hashable {
    var filter: TodoFilter = .today
    var grouping: TodoDateGrouping = .creation
}

struct TodoSection: Identifiable {
    enum ID: Hashable {
        case today
        case day(Date)
    }

    let id: ID
    let items: [TodoItem]
}
