import Defaults
import Foundation
@testable import Seven_Island

@main
@MainActor
enum TodoStoreTests {
    static func main() {
        let suiteName = "SevenIslandTodoTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let itemsKey = Defaults.Key<[TodoItem]>("items", default: [], suite: suite)
        let store = TodoStore(itemsKey: itemsKey)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19))!
        let today = calendar.date(byAdding: .day, value: 1, to: yesterday)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let now = today.addingTimeInterval(120)

        expect(store.add(" \n ", at: now) == nil, "ignores empty new items")
        let carried = store.add("之前未完成", at: today.addingTimeInterval(-60))!
        let earlierCompleted = store.add("昨天完成", at: yesterday.addingTimeInterval(100))!
        store.toggleCompletion(for: earlierCompleted, at: yesterday.addingTimeInterval(200))
        let current = store.add("  新待办  ", at: today.addingTimeInterval(60))!
        let currentCompleted = store.add("今天完成", at: now)!
        store.toggleCompletion(for: currentCompleted, at: now)

        let daily = store.sections(for: .today, on: now, in: calendar)
        expect(daily.map(\.id) == [.today], "combines today's tasks and carryover in a single list")
        expect(daily.flatMap(\.items).map(\.id) == [current, carried, currentCompleted],
               "puts all active tasks before completed items in Today")

        let all = store.sections(for: .all, on: now, in: calendar)
        expect(all.map(\.id) == [.day(today), .day(yesterday)], "sorts history by local creation date")
        expect(all[0].items.map(\.id) == [current, currentCompleted], "puts completed tasks last within each history date")
        expect(store.dates(in: calendar) == [today, yesterday], "exposes recorded dates once each")
        let history = store.sections(for: .day(yesterday), on: now, in: calendar)
        expect(history.flatMap(\.items).map(\.id) == [carried, earlierCompleted], "includes completed items in date history")

        store.toggleCompletion(for: current, at: now)
        let marking = store.sections(for: .today, on: now, in: calendar, retainingOrderFor: [current])
        expect(marking.flatMap(\.items).map(\.id) == [current, carried, currentCompleted],
               "leaves the row in place while its completion style animates")
        expect(marking.first?.items.first?.completedAt == now, "persists completion when the animation begins")
        expect(store.sections(for: .today, on: now, in: calendar).flatMap(\.items).map(\.id) == [carried, currentCompleted, current],
               "moves a newly completed task behind the active tasks")
        store.toggleCompletion(for: current, at: now)

        store.updateText(" \n ", for: current)
        expect(store.items.first { $0.id == current }?.text == "新待办", "preserves a title on empty edit")
        store.updateText(" 修改后的待办 ", for: current)
        store.toggleCompletion(for: carried, at: now)
        expect(store.sections(for: .today, on: now, in: calendar).flatMap(\.items).map(\.id) == [current, currentCompleted, carried],
               "keeps carryover finished today in the completed group")
        expect(store.sections(for: .day(yesterday), on: now, in: calendar).flatMap(\.items).map(\.id) == [carried, earlierCompleted],
               "keeps carryover grouped by its original date in history")

        let reloaded = TodoStore(itemsKey: itemsKey)
        expect(reloaded.items == store.items, "restores tasks and timestamps from the local store")
        expect(reloaded.items.first { $0.id == carried }?.completedAt == now, "records completion time")
        let edited = reloaded.items.first { $0.id == current }
        expect(edited?.text == "修改后的待办" && edited?.createdAt == today.addingTimeInterval(60),
               "editing preserves the original creation time")
        reloaded.toggleCompletion(for: carried, at: now)
        let nextDay = reloaded.sections(for: .today, on: tomorrow, in: calendar)
        expect(nextDay.map(\.id) == [.today] && nextDay.flatMap(\.items).map(\.id) == [current, carried],
               "moves open items to carryover as the local day changes")
        reloaded.delete(carried)
        expect(TodoStore(itemsKey: itemsKey).items.allSatisfy { $0.id != carried }, "persists deletion")

        let openFromYesterday = reloaded.add("昨天未完成", at: yesterday)!
        let todayIDs = Set(reloaded.items(matching: .today, on: now, in: calendar).map(\.id))
        expect(todayIDs == [current, currentCompleted, openFromYesterday], "Today clear uses the visible scope")
        let addedAfterRequest = reloaded.add("确认期间新增", at: now)!
        reloaded.delete(todayIDs)
        expect(Set(reloaded.items.map(\.id)) == [earlierCompleted, addedAfterRequest],
               "clearing the confirmed snapshot preserves other dates and subsequently added tasks")

        let selectedDateIDs = Set(reloaded.items(matching: .day(yesterday), on: now, in: calendar).map(\.id))
        reloaded.delete(selectedDateIDs)
        expect(reloaded.items.map(\.id) == [addedAfterRequest], "date clear targets the selected creation date")
        let allIDs = Set(reloaded.items(matching: .all, on: now, in: calendar).map(\.id))
        reloaded.delete(allIDs)
        expect(TodoStore(itemsKey: itemsKey).items.isEmpty, "persists clearing all tasks")

        print("TodoStoreTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
