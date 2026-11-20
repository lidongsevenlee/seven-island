import Combine
import Defaults
import Foundation

@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var items: [TodoItem]
    private let itemsKey: Defaults.Key<[TodoItem]>

    init(itemsKey: Defaults.Key<[TodoItem]> = .todoItems) {
        self.itemsKey = itemsKey
        items = Defaults[itemsKey]
    }

    @discardableResult
    func add(_ text: String, at date: Date = .now) -> UUID? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let item = TodoItem(id: UUID(), text: text, createdAt: date, completedAt: nil)
        save([item] + items)
        return item.id
    }

    func updateText(_ text: String, for id: UUID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = items.firstIndex(where: { $0.id == id }), items[index].text != text else { return }
        var next = items
        next[index].text = text
        save(next)
    }

    func toggleCompletion(for id: UUID, at date: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        next[index].completedAt = next[index].isCompleted ? nil : date
        save(next)
    }

    func delete(_ id: UUID) {
        delete([id])
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let next = items.filter { !ids.contains($0.id) }
        guard next.count != items.count else { return }
        save(next)
    }

    func dates(in calendar: Calendar) -> [Date] {
        Set(items.map { calendar.startOfDay(for: $0.createdAt) }).sorted(by: >)
    }

    func items(matching filter: TodoFilter, on referenceDate: Date, in calendar: Calendar) -> [TodoItem] {
        switch filter {
        case .today:
            let today = calendar.startOfDay(for: referenceDate)
            return items.filter { item in
                if item.createdAt >= today {
                    return calendar.isDate(item.createdAt, inSameDayAs: today)
                }
                guard let completedAt = item.completedAt else { return true }
                return calendar.isDate(completedAt, inSameDayAs: today)
            }
        case .all:
            return items
        case .day(let date):
            return items.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }
        }
    }

    func sections(
        for filter: TodoFilter, on referenceDate: Date, in calendar: Calendar,
        retainingOrderFor pendingCompletionIDs: Set<UUID> = []
    ) -> [TodoSection] {
        let ordered = items(matching: filter, on: referenceDate, in: calendar).sorted { first, second in
            let firstCompleted = first.isCompleted && !pendingCompletionIDs.contains(first.id)
            let secondCompleted = second.isCompleted && !pendingCompletionIDs.contains(second.id)
            if firstCompleted != secondCompleted { return !firstCompleted }
            return first.createdAt > second.createdAt
        }
        guard !ordered.isEmpty else { return [] }

        switch filter {
        case .today:
            return [TodoSection(id: .today, items: ordered)]
        case .all:
            let days = Dictionary(grouping: ordered) { calendar.startOfDay(for: $0.createdAt) }
            return days.keys.sorted(by: >).map { TodoSection(id: .day($0), items: days[$0, default: []]) }
        case .day(let day):
            let start = calendar.startOfDay(for: day)
            return [TodoSection(id: .day(start), items: ordered)]
        }
    }

    private func save(_ next: [TodoItem]) {
        Defaults[itemsKey] = next
        items = next
    }
}
