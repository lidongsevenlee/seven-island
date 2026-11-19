import Combine
import Defaults
import Foundation

@MainActor
final class MemoStore: ObservableObject {
    static let shared = MemoStore()

    @Published private(set) var library: MemoLibrary
    private let libraryKey: Defaults.Key<MemoLibrary?>

    init(
        libraryKey: Defaults.Key<MemoLibrary?> = .memoLibrary,
        legacyTextKey: Defaults.Key<String> = .memoText
    ) {
        self.libraryKey = libraryKey
        if var saved = Defaults[libraryKey] {
            if !saved.items.contains(where: { $0.id == saved.selectedID }) {
                saved.selectedID = saved.items.first?.id
            }
            saved.nextNumber = max(saved.nextNumber, (saved.items.map(\.number).max() ?? 0) + 1)
            library = saved
        } else {
            let memo = MemoItem(number: 1, text: Defaults[legacyTextKey])
            library = MemoLibrary(items: [memo], selectedID: memo.id, nextNumber: 2)
        }
        Defaults[libraryKey] = library
        legacyTextKey.reset()
    }

    var selectedMemo: MemoItem? {
        library.items.first { $0.id == library.selectedID }
    }

    func memo(id: UUID) -> MemoItem? {
        library.items.first { $0.id == id }
    }

    @discardableResult
    func createMemo() -> UUID {
        var next = library
        let memo = MemoItem(number: next.nextNumber)
        next.items.append(memo)
        next.selectedID = memo.id
        next.nextNumber += 1
        save(next)
        return memo.id
    }

    func selectMemo(id: UUID) {
        guard library.items.contains(where: { $0.id == id }) else { return }
        var next = library
        next.selectedID = id
        save(next)
    }

    func updateText(_ text: String, for id: UUID) {
        guard let index = library.items.firstIndex(where: { $0.id == id }) else { return }
        var next = library
        next.items[index].text = text
        save(next)
    }

    func deleteMemo(id: UUID) {
        guard let index = library.items.firstIndex(where: { $0.id == id }) else { return }
        var next = library
        next.items.remove(at: index)
        if next.selectedID == id {
            next.selectedID = next.items.isEmpty ? nil : next.items[min(index, next.items.count - 1)].id
        }
        save(next)
    }

    private func save(_ next: MemoLibrary) {
        guard next != library else { return }
        Defaults[libraryKey] = next
        library = next
    }
}
