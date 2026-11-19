import Defaults
import Foundation
@testable import Seven_Island

@main
@MainActor
enum MemoStoreTests {
    static func main() {
        withLibrary { libraryKey, legacyKey in
            let original = "原有备忘录\n第二行，保留中文和换行。"
            Defaults[legacyKey] = original
            let store = MemoStore(libraryKey: libraryKey, legacyTextKey: legacyKey)
            expect(store.library.items.count == 1, "migrates one legacy memo")
            expect(store.selectedMemo?.text == original, "preserves legacy text exactly")
            expect(Defaults[legacyKey].isEmpty, "retires legacy storage after migration")

            let firstID = store.selectedMemo!.id
            let secondID = store.createMemo()
            expect(store.selectedMemo?.title == "备忘录2", "names a new empty memo")
            store.updateText("  \n  购物清单  \n牛奶\n面包", for: secondID)
            expect(store.selectedMemo?.title == "购物清单", "uses the first nonblank line as title")
            store.selectMemo(id: firstID)
            expect(store.selectedMemo?.text == original, "switches to the corresponding content")
            store.updateText("购物清单\n鸡蛋", for: secondID)
            expect(store.selectedMemo?.text == original, "routes a late editor update by memo identity")

            let restored = MemoStore(libraryKey: libraryKey, legacyTextKey: legacyKey)
            expect(restored.library == store.library, "restores tab order, contents, and selection")
            expect(restored.memo(id: secondID)?.text == "购物清单\n鸡蛋", "persists independent memo edits")
        }

        withLibrary { libraryKey, legacyKey in
            let store = MemoStore(libraryKey: libraryKey, legacyTextKey: legacyKey)
            let firstID = store.selectedMemo!.id
            let secondID = store.createMemo()
            let thirdID = store.createMemo()
            store.selectMemo(id: secondID)
            store.deleteMemo(id: secondID)
            expect(store.library.selectedID == thirdID, "selects the next tab after deleting the current tab")
            store.updateText("late edit", for: secondID)
            expect(store.selectedMemo?.text == "", "ignores an editor callback for a deleted memo")
            store.deleteMemo(id: firstID)
            expect(store.library.selectedID == thirdID, "keeps selection when deleting an inactive tab")
            let fourthID = store.createMemo()
            store.deleteMemo(id: fourthID)
            expect(store.library.selectedID == thirdID, "selects the previous tab after deleting the last tab")
            store.deleteMemo(id: thirdID)
            expect(store.library.items.isEmpty && store.selectedMemo == nil, "supports deleting all memos")

            Defaults[legacyKey] = "stale legacy copy"
            let restored = MemoStore(libraryKey: libraryKey, legacyTextKey: legacyKey)
            expect(restored.library.items.isEmpty, "preserves an empty library across restart")
            restored.createMemo()
            expect(restored.selectedMemo?.title == "备忘录5", "preserves new memo numbering after deletion and restart")
        }

        withLibrary { libraryKey, legacyKey in
            let memo = MemoItem(number: 8, text: String(repeating: "长", count: 60))
            Defaults[libraryKey] = MemoLibrary(items: [memo], selectedID: UUID(), nextNumber: 1)
            let store = MemoStore(libraryKey: libraryKey, legacyTextKey: legacyKey)
            expect(store.selectedMemo?.id == memo.id, "recovers a missing selected tab")
            expect(store.selectedMemo?.title.count == 40, "bounds long tab titles")
            store.createMemo()
            expect(store.selectedMemo?.number == 9, "normalizes the next memo number")
        }
        print("MemoStoreTests passed")
    }

    private static func withLibrary(_ body: (Defaults.Key<MemoLibrary?>, Defaults.Key<String>) -> Void) {
        let suiteName = "SevenIslandMemoTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        body(
            Defaults.Key<MemoLibrary?>("library", suite: suite),
            Defaults.Key<String>("legacy", default: "", suite: suite)
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
