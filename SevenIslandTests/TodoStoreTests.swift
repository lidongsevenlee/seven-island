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

        testReordering(itemsKey: itemsKey, today: today, now: now, calendar: calendar)
        let completionKey = Defaults.Key<[TodoItem]>("completionItems", default: [], suite: suite)
        testCompletionGrouping(itemsKey: completionKey, yesterday: yesterday, today: today, tomorrow: tomorrow,
                               calendar: calendar)
        let weekKey = Defaults.Key<[TodoItem]>("weekItems", default: [], suite: suite)
        testWeekDates(itemsKey: weekKey, in: calendar)
        print("TodoStoreTests passed")
    }

    private static func testWeekDates(itemsKey: Defaults.Key<[TodoItem]>, in calendar: Calendar) {
        var calendar = calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let start = calendar.date(from: DateComponents(year: 2026, month: 12, day: 28))!
        let previous = calendar.date(byAdding: .day, value: -1, to: start)!
        let newYear = calendar.date(byAdding: .day, value: 4, to: start)!
        let end = calendar.date(byAdding: .day, value: 6, to: start)!
        let next = calendar.date(byAdding: .day, value: 7, to: start)!
        let store = TodoStore(itemsKey: itemsKey)
        store.add("本周创建", at: start)
        let finished = store.add("前一周创建", at: previous)!
        store.toggleCompletion(for: finished, at: newYear)
        store.add("本周末创建", at: end)
        let sameDay = store.add("同一天完成", at: end)!
        store.toggleCompletion(for: sameDay, at: end)
        store.add("下周创建", at: next)

        expect(store.dates(inWeekContaining: newYear, in: calendar) == [end, newYear, start],
               "includes unique creation and completion dates across a year boundary within the chosen week")
        expect(store.dates(inWeekContaining: next, in: calendar) == [next], "switches to the following week at its boundary")
        store.toggleCompletion(for: finished, at: next)
        expect(store.dates(inWeekContaining: newYear, in: calendar) == [end, start],
               "undoing completion removes a completion-only date from the week")
    }

    private static func testCompletionGrouping(
        itemsKey: Defaults.Key<[TodoItem]>, yesterday: Date, today: Date, tomorrow: Date, calendar: Calendar
    ) {
        let store = TodoStore(itemsKey: itemsKey)
        let older = yesterday.addingTimeInterval(-60)
        let open = store.add("还未完成", at: older)!
        let historical = store.add("昨天完成", at: older)!
        let carryover = store.add("隔天完成", at: yesterday)!
        let sameDay = store.add("当天完成", at: today)!
        let laterCompletion = today.addingTimeInterval(120)
        store.toggleCompletion(for: historical, at: yesterday)
        store.toggleCompletion(for: sameDay, at: today.addingTimeInterval(60))
        store.toggleCompletion(for: carryover, at: laterCompletion)

        expect(store.dates(groupedBy: .completion, in: calendar) == [today, yesterday],
               "derives date chips from completion dates")
        let completed = store.sections(for: .all, groupedBy: .completion, on: laterCompletion, in: calendar)
        expect(completed.map(\.id) == [.day(today), .day(yesterday)], "groups completed history by local completion day")
        expect(completed.map { $0.items.map(\.id) } == [[carryover, sameDay], [historical]],
               "orders by completion time within each day and filters open tasks")

        let todayCompleted = store.sections(for: .today, groupedBy: .completion, on: laterCompletion, in: calendar)
        expect(todayCompleted.first?.id == .today && todayCompleted.first?.items.map(\.id) == [carryover, sameDay],
               "Today selects tasks completed today across creation dates")
        let yesterdayCompleted = store.items(matching: .day(yesterday), groupedBy: .completion,
                                             on: laterCompletion, in: calendar)
        expect(yesterdayCompleted.map(\.id) == [historical], "a single completion date uses the same scope as its clear action")
        let allCompleted = store.items(matching: .all, groupedBy: .completion, on: laterCompletion, in: calendar)
        expect(Set(allCompleted.map(\.id)) == [historical, carryover, sameDay], "All completed excludes open tasks from its clear scope")
        let yesterdayCreated = store.items(matching: .day(yesterday), on: laterCompletion, in: calendar)
        expect(yesterdayCreated.map(\.id) == [carryover], "creation dates retain tasks finished on a later day")

        expect(store.move(carryover, onto: sameDay, in: .all, groupedBy: .completion, on: laterCompletion, using: calendar),
               "supports reordering tasks in the same completion group")
        expect(!store.move(carryover, onto: historical, in: .all, groupedBy: .completion, on: laterCompletion, using: calendar),
               "keeps reordering inside a completion-date group")
        let reloaded = TodoStore(itemsKey: itemsKey)
        let reloadedOrder = reloaded.sections(for: .today, groupedBy: .completion, on: laterCompletion, in: calendar)
        expect(reloadedOrder.first?.items.map(\.id) == [sameDay, carryover], "persists completion-group order")

        reloaded.toggleCompletion(for: historical, at: laterCompletion)
        expect(reloaded.dates(groupedBy: .completion, in: calendar) == [today], "removes an empty completion date")
        expect(TodoStore(itemsKey: itemsKey).items.first { $0.id == historical }?.completedAt == nil,
               "persisted undo clears the recorded completion time")
        let remainingCreated = reloaded.items(matching: .today, on: laterCompletion, in: calendar)
        expect(Set(remainingCreated.map(\.id)) == [open, historical, carryover, sameDay],
               "undo returns a task to the creation-mode carryover list")

        reloaded.toggleCompletion(for: historical, at: tomorrow)
        let newCompletion = reloaded.sections(for: .today, groupedBy: .completion, on: tomorrow, in: calendar)
        expect(newCompletion.first?.items.first?.completedAt == tomorrow, "re-completing records the new completion time")
    }

    private static func testReordering(itemsKey: Defaults.Key<[TodoItem]>, today: Date, now: Date, calendar: Calendar) {
        let store = TodoStore(itemsKey: itemsKey)
        let carryoverDate = today.addingTimeInterval(-60)
        let carryover = store.add("之前的待办", at: carryoverDate)!
        let first = store.add("第一项", at: today)!
        let second = store.add("第二项", at: today.addingTimeInterval(60))!
        let completed = store.add("已完成", at: now)!
        store.toggleCompletion(for: completed, at: now)

        expect(store.move(carryover, onto: second, in: .today, on: now, using: calendar), "moves a carryover task up in Today")
        expect(store.sections(for: .today, on: now, in: calendar).flatMap(\.items).map(\.id) == [carryover, second, first, completed],
               "reorders open tasks together and keeps completed tasks below them")
        expect(!store.move(carryover, onto: second, in: .all, on: now, using: calendar), "keeps tasks in their original date groups")
        expect(!store.move(first, onto: completed, in: .today, on: now, using: calendar), "keeps open and completed tasks in their groups")
        expect(!store.move(first, onto: first, in: .today, on: now, using: calendar), "ignores dropping a task onto itself")
        expect(store.move(second, onto: first, in: .day(today), on: now, using: calendar), "moves a task down in a date filter")

        let reloaded = TodoStore(itemsKey: itemsKey)
        expect(reloaded.sections(for: .today, on: now, in: calendar).flatMap(\.items).map(\.id) == [carryover, first, second, completed],
               "restores the shared ordering across filters")
        expect(reloaded.sections(for: .all, on: now, in: calendar).first?.items.map(\.id) == [first, second, completed],
               "uses manual ordering inside a history group")
        expect(reloaded.items.first { $0.id == carryover }?.createdAt == carryoverDate, "keeps creation time after reordering")
        expect(reloaded.items.first { $0.id == completed }?.completedAt == now, "keeps completion time after reordering")
        let added = reloaded.add("新待办", at: now)!
        expect(reloaded.sections(for: .today, on: now, in: calendar).first?.items.first?.id == added,
               "places new tasks at the top after manual sorting")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
