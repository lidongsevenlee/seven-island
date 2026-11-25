import Defaults
import SwiftUI

private let todoFilterIconStroke = StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)

@MainActor
struct TodoView: View {
    private static let rowSpacing: CGFloat = 4
    private static let filterIconSize: CGFloat = 16

    struct Presentation: Hashable {
        let expansionCycle: Int
        let tabSelectionCycle: Int
    }

    let compactContentHeight: CGFloat
    let presentation: Presentation
    @Binding var scope: TodoListScope
    @Binding var calendarWeek: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = TodoStore.shared
    @FocusState private var field: Field?
    @State private var historyDatesExpanded = true
    @State private var referenceDate = Date.now
    @State private var calendarSelection = Date.now
    @State private var isCalendarPresented = false
    @State private var newText = ""
    @State private var editingID: UUID?
    @State private var editedText = ""
    @State private var todoPendingDeletion: UUID?
    @State private var pendingClear: ClearRequest?
    @State private var pendingCompletionMoves: [UUID: UUID] = [:]
    @State private var reorder = RowReorder<UUID>(spacing: Self.rowSpacing)
    @State private var controlsHeight: CGFloat = 0
    @State private var listMeasurement: ListMeasurement?

    private let spacing: CGFloat = 8
    private let rowControlHeight: CGFloat = 20
    private let rowVerticalInset: CGFloat = 5
    private let eagerRowLimit = 24

    private var maximumContentHeight: CGFloat { compactContentHeight * 2 }
    private var panelAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }
    private var filter: TodoFilter { scope.filter }
    private var grouping: TodoDateGrouping { scope.grouping }
    private var displayedWeekDate: Date { calendarWeek ?? referenceDate }
    private var emptyMessage: String {
        if grouping == .completion {
            return filter == .today ? "今天还没有完成的待办" : "这段时间没有完成的待办"
        }
        return filter == .today ? "今天还没有待办" : "这段时间没有待办"
    }
    private var isCurrentPresentation: Bool {
        vm.notchState == .open && vm.coordinator.currentView == .todo
            && vm.expansionCycle == presentation.expansionCycle
            && vm.coordinator.tabSelectionCycle == presentation.tabSelectionCycle
    }

    private struct ListMeasurement: Equatable {
        let scope: TodoListScope
        let rowCount: Int
        let height: CGFloat
    }

    private struct ClearRequest {
        let ids: Set<UUID>
        let scope: String
    }

    private enum ListEntry: Identifiable {
        case date(Date)
        case item(TodoItem)

        var id: AnyHashable {
            switch self {
            case .date(let date): date
            case .item(let item): item.id
            }
        }
    }

    private enum Field: Hashable {
        case newItem
        case edit(UUID)
    }

    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        let scope = scope
        let sections = store.sections(for: scope.filter, groupedBy: scope.grouping, on: referenceDate, in: calendar,
                                      retainingOrderFor: Set(pendingCompletionMoves.keys))
        let entries = sections.flatMap { section -> [ListEntry] in
            let items = section.items.map(ListEntry.item)
            if case .day(let date) = section.id { return [.date(date)] + items }
            return items
        }
        let reorderGroups = pendingCompletionMoves.isEmpty ? sections.flatMap { section in
            let groups = Dictionary(grouping: section.items, by: \.isCompleted)
            return [false, true].compactMap { groups[$0]?.map(\.id) }
        } : []
        let dates = store.dates(inWeekContaining: displayedWeekDate, in: calendar)
        let minimumRowHeight = rowControlHeight + 2 * rowVerticalInset
        let rowCount = sections.reduce(0) { $0 + $1.items.count }
        // The panel can use its height cap once the minimum row heights fill it.
        let fillsAvailableHeight = rowCount > 0
            && CGFloat(rowCount) * minimumRowHeight >= maximumContentHeight - controlsHeight - spacing
        let panelHeight = preferredPanelHeight(rowCount: rowCount, fillsAvailableHeight: fillsAvailableHeight)

        VStack(alignment: .leading, spacing: spacing) {
            VStack(alignment: .leading, spacing: spacing) {
                composer
                filters(dates, in: calendar, todayHasItems: scope.filter == .today ? rowCount > 0 : nil)
                if let pendingClear { clearConfirmation(pendingClear) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }

            if sections.isEmpty {
                EmptyStateView(message: emptyMessage)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: ListMeasurement.self) { geometry in
                        ListMeasurement(scope: scope, rowCount: rowCount, height: geometry.size.height)
                    } action: { listMeasurement = $0 }
            } else {
                ScrollView {
                    if rowCount > eagerRowLimit && fillsAvailableHeight {
                        LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                            listRows(entries, in: calendar)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Self.rowSpacing) {
                            listRows(entries, in: calendar)
                        }
                        .onGeometryChange(for: ListMeasurement.self) { geometry in
                            ListMeasurement(scope: scope, rowCount: rowCount, height: geometry.size.height)
                        } action: { measurement in
                            if !fillsAvailableHeight { listMeasurement = measurement }
                        }
                    }
                }
                .id(scope)
            }
        }
        .task(id: scope) {
            guard scope.filter == .all, !historyDatesExpanded else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                historyDatesExpanded = true
            }
        }
        .task(id: vm.notchState) {
            guard vm.notchState == .open else { return }
            if Defaults[.showOnAllDisplays], let display = vm.display, !display.frame.contains(NSEvent.mouseLocation) {
                return
            }

            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, isCurrentPresentation, field == nil, editingID == nil else { return }
            vm.makePanelKeyForKeyboardInput()
            field = .newItem
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in referenceDate = .now }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in referenceDate = .now }
        .onChange(of: isCalendarPresented) { _, presented in
            if isCurrentPresentation { vm.setTodoCalendarPresented(presented) }
        }
        .onChange(of: scope) { _, _ in
            todoPendingDeletion = nil
            pendingClear = nil
            reorder.reset()
        }
        .onChange(of: reorderGroups, initial: true) { _, groups in reorder.setGroups(groups) }
        .onChange(of: reorder.source != nil) { _, active in
            if isCurrentPresentation { vm.setTodoReordering(active) }
        }
        .onChange(of: panelHeight, initial: true) { _, height in
            guard let height, isCurrentPresentation else { return }
            withAnimation(panelAnimation) {
                vm.setOpenNotchHeight(height, minimum: openNotchSize.height - compactContentHeight)
            }
        }
        .onChange(of: field) { previous, current in
            guard isCurrentPresentation else { return }
            if current != nil { vm.makePanelKeyForKeyboardInput() }
            vm.isTextInputFocused = current != nil
            if case .edit(let id) = previous, id == editingID { finishEdit() }
        }
        .onDisappear {
            finishEdit()
            if vm.expansionCycle == presentation.expansionCycle,
               vm.coordinator.currentView != .todo || isCurrentPresentation {
                vm.isTextInputFocused = false
                vm.setTodoReordering(false)
                vm.setTodoCalendarPresented(false)
            }
            todoPendingDeletion = nil
            pendingClear = nil
            pendingCompletionMoves.removeAll()
            reorder.reset()
        }
        .preferredColorScheme(.dark)
    }

    private func preferredPanelHeight(rowCount: Int, fillsAvailableHeight: Bool) -> CGFloat? {
        guard controlsHeight > 0 else { return nil }
        let panelInsets = openNotchSize.height - compactContentHeight
        if fillsAvailableHeight { return panelInsets + maximumContentHeight }
        guard let listMeasurement, listMeasurement.scope == scope, listMeasurement.rowCount == rowCount else { return nil }
        return panelInsets + min(controlsHeight + spacing + listMeasurement.height, maximumContentHeight)
    }

    private var composer: some View {
        HStack(spacing: sevenIslandRowSpacing) {
            TextField("添加待办…", text: $newText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($field, equals: .newItem)
                .onSubmit(addTodo)

            Button(action: addTodo) {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("添加待办")
        }
        .padding(.horizontal, sevenIslandRowInset)
        .padding(.vertical, 4)
        .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private func filters(_ dates: [Date], in calendar: Calendar, todayHasItems: Bool?) -> some View {
        let canClearToday = todayHasItems ?? !store.items(
            matching: .today, groupedBy: grouping, on: referenceDate, in: calendar
        ).isEmpty
        let datesWithMatchingItems = Set(store.dates(groupedBy: grouping, in: calendar))
        return HStack(spacing: 6) {
            filterButton(Text("今天"), for: .today, canClear: canClearToday)
            filterButton(Text("全部"), for: .all, canClear: !datesWithMatchingItems.isEmpty)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(dates, id: \.self) { date in
                        filterButton(dateLabel(date, in: calendar), for: .day(date),
                                     canClear: datesWithMatchingItems.contains(date))
                    }
                }
            }

            groupingButton
            calendarButton(in: calendar)
        }
        .frame(height: 24)
    }

    private var groupingButton: some View {
        let byCompletion = grouping == .completion
        return Button {
            selectGrouping(byCompletion ? .creation : .completion)
        } label: {
            TodoGroupingClock(isCompleted: byCompletion)
                .stroke(style: todoFilterIconStroke)
                .foregroundStyle(byCompletion ? .white : .secondary)
                .frame(width: Self.filterIconSize, height: Self.filterIconSize)
                .frame(width: 24, height: 24)
                .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(byCompletion ? "按完成时间分类" : "按创建时间分类")
        .accessibilityLabel("待办时间分类")
        .accessibilityValue(byCompletion ? "完成时间" : "创建时间")
        .accessibilityHint(byCompletion ? "切换到创建时间" : "切换到完成时间")
    }

    private func calendarButton(in calendar: Calendar) -> some View {
        let selectedDay: Date? = if case .day(let date) = filter { date } else { nil }
        let isShowingAnotherWeek = !calendar.isDate(displayedWeekDate, equalTo: referenceDate, toGranularity: .weekOfYear)
        return Button {
            if isCalendarPresented {
                isCalendarPresented = false
                return
            }
            finishEdit()
            calendarSelection = selectedDay ?? displayedWeekDate
            vm.setTodoCalendarPresented(true)
            isCalendarPresented = true
        } label: {
            TodoCalendarIcon()
                .fill()
                .foregroundStyle(isShowingAnotherWeek ? .white : .secondary)
                .frame(width: Self.filterIconSize, height: Self.filterIconSize)
                .frame(width: 24, height: 24)
                .background(
                    isShowingAnotherWeek ? sevenIslandHoveredContentBackground : sevenIslandContentBackground,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .help("筛选日期")
        .accessibilityLabel("筛选日期")
        .accessibilityValue(selectedDay?.formatted(date: .abbreviated, time: .omitted) ?? "")
        .background {
            TodoCalendarPopover(isPresented: $isCalendarPresented, date: calendarSelection, calendar: calendar) { date in
                let day = calendar.startOfDay(for: date)
                calendarWeek = day
                selectFilter(.day(day))
                vm.setTodoCalendarPresented(false, keepingPanelOpen: true)
                isCalendarPresented = false
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func filterButton(_ label: Text, for selection: TodoFilter, canClear: Bool) -> some View {
        let selected = filter == selection
        return Button {
            finishEdit()
            selectFilter(selection)
        } label: {
            label
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    selected ? sevenIslandHoveredContentBackground : sevenIslandContentBackground,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("清空全部", role: .destructive) { requestClear(selection) }
                .disabled(!canClear)
        }
    }

    private func selectFilter(_ selection: TodoFilter) {
        if selection == .today, calendarWeek != nil { calendarWeek = nil }
        selectScope(TodoListScope(filter: selection, grouping: grouping))
    }

    private func selectGrouping(_ grouping: TodoDateGrouping) {
        finishEdit()
        selectScope(TodoListScope(filter: filter, grouping: grouping))
    }

    private func selectScope(_ next: TodoListScope) {
        guard scope != next else { return }
        if next.filter == .all { historyDatesExpanded = reduceMotion }
        scope = next
    }

    private func requestClear(_ selection: TodoFilter) {
        let items = store.items(matching: selection, groupedBy: grouping, on: referenceDate, in: .autoupdatingCurrent)
        guard !items.isEmpty else { return }
        finishEdit()
        todoPendingDeletion = nil

        let scope: String
        switch selection {
        case .today:
            scope = grouping == .completion ? "「今天完成」" : "「今天」（含带入的历史待办）"
        case .all:
            scope = grouping == .completion ? "「全部已完成」" : "「全部」"
        case .day(let date):
            let day = date.formatted(date: .abbreviated, time: .omitted)
            scope = grouping == .completion ? "\(day)完成" : day
        }
        pendingClear = ClearRequest(ids: Set(items.map(\.id)), scope: scope)
    }

    private func clearConfirmation(_ request: ClearRequest) -> some View {
        let count = store.items.lazy.filter { request.ids.contains($0.id) }.count
        return HStack(spacing: 8) {
            Text("清空\(request.scope)的 \(count) 条待办？")
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("取消") { pendingClear = nil }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            Button("确认清空", role: .destructive) {
                deleteTodos(request.ids)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(count == 0)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, sevenIslandRowInset)
        .padding(.vertical, 7)
        .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private func dateLabel(_ day: Date, in calendar: Calendar) -> Text {
        if calendar.isDate(day, equalTo: referenceDate, toGranularity: .year) {
            Text(day, format: .dateTime.month(.defaultDigits).day())
        } else {
            Text(day, format: .dateTime.year().month(.defaultDigits).day())
        }
    }

    private func listRows(_ entries: [ListEntry], in calendar: Calendar) -> some View {
        ForEach(entries) { entry in
            switch entry {
            case .date(let date):
                TodoDateHeaderLayout(expansion: filter == .all && !historyDatesExpanded ? 0 : 1) {
                    dateLabel(date, in: calendar)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, entry.id == entries.first?.id ? 0 : 4)
                }
                .clipped()
                .accessibilityAddTraits(.isHeader)
                .transition(.opacity)
            case .item(let item):
                let sectionDate = filter == .today ? referenceDate : (grouping.date(for: item) ?? item.createdAt)
                row(item, sectionDate: calendar.startOfDay(for: sectionDate))
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.97))))
            }
        }
    }

    private func row(_ item: TodoItem, sectionDate: Date) -> some View {
        let isConfirmingDeletion = todoPendingDeletion == item.id
        return TodoRow(item: item, sectionDate: sectionDate, isEditing: editingID == item.id,
                       isConfirmingDeletion: isConfirmingDeletion) { isHovered in
            rowContent(item, sectionDate: sectionDate, isConfirmingDeletion: isConfirmingDeletion, isHovered: isHovered)
        }
        .equatable()
        .contextMenu {
            Button("编辑待办") { edit(item) }
            Button(isConfirmingDeletion ? "确认删除待办" : "删除待办", role: .destructive) {
                deleteOrConfirm(item)
            }
        }
        .reorderRow(item.id, in: reorder, background: Color(white: 0.16))
    }

    private func rowContent(
        _ item: TodoItem, sectionDate: Date, isConfirmingDeletion: Bool, isHovered: Bool
    ) -> some View {
        let showsReorderHandle = isHovered || reorder.source == item.id
        let showsDeleteButton = isHovered || isConfirmingDeletion
        let hoverAnimation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.12)

        return HStack(spacing: sevenIslandRowSpacing) {
            Button {
                toggleCompletion(for: item.id)
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isCompleted ? Color.white : Color.secondary)
                    .frame(width: sevenIslandRowIconWidth, height: rowControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "将\(item.text)标记为未完成" : "将\(item.text)标记为完成")

            if editingID == item.id {
                TextField("编辑待办", text: $editedText)
                    .textFieldStyle(.plain)
                    .focused($field, equals: .edit(item.id))
                    .onSubmit { finishEdit() }
                    .onExitCommand { finishEdit(save: false) }
                    .task {
                        await Task.yield()
                        guard !Task.isCancelled, editingID == item.id else { return }
                        vm.makePanelKeyForKeyboardInput()
                        field = .edit(item.id)
                    }

                Button {
                    finishEdit()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("保存修改")
            } else {
                Button {
                    edit(item)
                } label: {
                    TodoTitle(text: item.text, completionProgress: item.isCompleted ? 1 : 0)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("编辑待办")
                .accessibilityAction(named: Text(isConfirmingDeletion ? "确认删除待办" : "删除待办")) {
                    deleteOrConfirm(item)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: rowControlHeight)
                    .contentShape(Rectangle())
                    .reorderHandle(for: item.id, in: reorder) { target in
                        guard isCurrentPresentation, pendingCompletionMoves.isEmpty else { return nil }
                        let scope = scope
                        let date = referenceDate
                        return {
                            store.move(item.id, onto: target, in: scope.filter, groupedBy: scope.grouping,
                                       on: date, using: .autoupdatingCurrent)
                        }
                    }
                    .help("拖动排序")
                    .accessibilityLabel("拖动\(item.text)调整顺序")
                    .opacity(showsReorderHandle ? 1 : 0)
                    .allowsHitTesting(showsReorderHandle)
                    .accessibilityHidden(!showsReorderHandle)
                    .animation(hoverAnimation, value: showsReorderHandle)

                Color.clear
                    .frame(width: 26, height: rowControlHeight)
                    .overlay(alignment: .trailing) {
                        if showsDeleteButton {
                            InlineDeleteButton(
                                itemTitle: item.text,
                                deleteLabel: "删除待办",
                                isConfirming: isConfirmingDeletion,
                                color: .secondary,
                                action: { deleteOrConfirm(item) }
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(hoverAnimation, value: showsDeleteButton)
            }

            if editingID != item.id {
                HStack(spacing: 8) {
                    if let completedAt = item.completedAt {
                        timestamp(completedAt, relativeTo: sectionDate, isCompletion: true)
                    }
                    timestamp(item.createdAt, relativeTo: sectionDate)
                }
                .font(.system(size: 11).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, sevenIslandRowInset)
        .padding(.vertical, rowVerticalInset)
        .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private func timestamp(_ date: Date, relativeTo sectionDate: Date, isCompletion: Bool = false) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        let time = Text(date, format: .dateTime.hour().minute())
        let text = calendar.isDate(date, inSameDayAs: sectionDate) ? time : Text("\(dateLabel(date, in: calendar)) \(time)")
        let title = isCompletion ? "完成于" : "创建于"
        let label = "\(title) \(date.formatted(date: .abbreviated, time: .shortened))"
        return text
            .strikethrough(isCompletion)
            .help(label)
            .accessibilityLabel(label)
    }

    private func addTodo() {
        finishEdit()
        let date = Date.now
        guard store.add(newText, at: date) != nil else { return }
        referenceDate = date
        newText = ""
        todoPendingDeletion = nil
        pendingClear = nil
        if calendarWeek != nil { calendarWeek = nil }
        selectScope(TodoListScope())
    }

    private func edit(_ item: TodoItem) {
        guard editingID != item.id else { return }
        finishEdit()
        todoPendingDeletion = nil
        editingID = item.id
        editedText = item.text
    }

    private func finishEdit(save: Bool = true) {
        guard let id = editingID else { return }
        if save { store.updateText(editedText, for: id) }
        editingID = nil
        if field == .edit(id) { field = nil }
    }

    private func deleteOrConfirm(_ item: TodoItem) {
        if todoPendingDeletion == item.id {
            deleteTodos([item.id])
        } else {
            todoPendingDeletion = item.id
        }
    }

    private func toggleCompletion(for id: UUID) {
        guard let item = store.items.first(where: { $0.id == id }) else { return }
        if editingID == id { finishEdit() }
        todoPendingDeletion = nil

        if item.isCompleted || reduceMotion {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                pendingCompletionMoves[id] = nil
                store.toggleCompletion(for: id)
            }
            return
        }

        let move = UUID()
        withAnimation(.easeInOut(duration: 0.2), completionCriteria: .logicallyComplete) {
            pendingCompletionMoves[id] = move
            store.toggleCompletion(for: id)
        } completion: {
            guard pendingCompletionMoves[id] == move else { return }
            withAnimation(.smooth(duration: 0.28)) {
                pendingCompletionMoves[id] = nil
            }
        }
    }

    private func deleteTodos(_ ids: Set<UUID>) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            if let editingID, ids.contains(editingID) { finishEdit(save: false) }
            todoPendingDeletion = nil
            if pendingClear?.ids == ids { pendingClear = nil }
            pendingCompletionMoves = pendingCompletionMoves.filter { !ids.contains($0.key) }
            store.delete(ids)
        }
    }
}

private struct TodoGroupingClock: Shape {
    let isCompleted: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: 7.6, y: 7.6), radius: 6.7,
                    startAngle: .degrees(82), endAngle: .degrees(363), clockwise: false)
        path.move(to: CGPoint(x: 7.6, y: 3.8))
        path.addLine(to: CGPoint(x: 7.6, y: 7.6))
        path.addLine(to: CGPoint(x: 10.1, y: 8.9))

        if isCompleted {
            path.move(to: CGPoint(x: 11.1, y: 12.3))
            path.addLine(to: CGPoint(x: 12.75, y: 13.95))
            path.addLine(to: CGPoint(x: 15.35, y: 11.35))
        } else {
            path.move(to: CGPoint(x: 11.55, y: 11.5))
            path.addLine(to: CGPoint(x: 14.75, y: 14.7))
            path.move(to: CGPoint(x: 14.75, y: 11.5))
            path.addLine(to: CGPoint(x: 11.55, y: 14.7))
        }

        let scale = min(rect.width, rect.height) / 16
        let transform = CGAffineTransform(translationX: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
            .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}

private struct TodoCalendarIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var outline = Path(roundedRect: CGRect(x: 1.25, y: 2.6, width: 13.5, height: 12.05), cornerRadius: 1.25)
        outline.move(to: CGPoint(x: 1.25, y: 6.15))
        outline.addLine(to: CGPoint(x: 14.75, y: 6.15))

        for x: CGFloat in [5, 11] {
            outline.move(to: CGPoint(x: x, y: 1.3))
            outline.addLine(to: CGPoint(x: x, y: 4.15))
        }

        var path = outline.strokedPath(todoFilterIconStroke)
        let columns: [CGFloat] = [4.5, 8, 11.5]
        let rows: [CGFloat] = [8.85, 11.8]
        for y in rows {
            for x in columns {
                path.addRect(CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3))
            }
        }

        let scale = min(rect.width, rect.height) / 16
        let transform = CGAffineTransform(translationX: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
            .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}

private struct TodoCalendarPopover: NSViewRepresentable {
    @Binding var isPresented: Bool
    let date: Date
    let calendar: Calendar
    let select: (Date) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ anchor: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.select = select
        coordinator.dismiss = { isPresented = false }
        if isPresented {
            coordinator.show(anchor: anchor, date: date, calendar: calendar)
        } else {
            coordinator.hide()
        }
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) {
        coordinator.hide()
    }

    @MainActor
    final class Coordinator: NSObject {
        var select: ((Date) -> Void)?
        var dismiss: (() -> Void)?
        private var panel: TodoCalendarPanel?
        private var localMonitor: Any?

        func show(anchor: NSView, date: Date, calendar: Calendar) {
            guard panel == nil, let parent = anchor.window else { return }
            let picker = NSDatePicker()
            picker.datePickerStyle = .clockAndCalendar
            picker.datePickerElements = .yearMonthDay
            picker.datePickerMode = .single
            picker.calendar = calendar
            picker.locale = calendar.locale ?? .autoupdatingCurrent
            picker.timeZone = calendar.timeZone
            picker.dateValue = date
            picker.isBordered = false
            picker.isBezeled = false
            picker.drawsBackground = false
            picker.focusRingType = .none
            picker.cell?.focusRingType = .none
            picker.controlSize = .large
            picker.setAccessibilityLabel("筛选日期")
            picker.sizeToFit()

            let padding: CGFloat = 6
            let size = CGSize(width: picker.frame.width + 2 * padding, height: picker.frame.height + 2 * padding)
            let source = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let visible = parent.screen?.visibleFrame
            let desiredX = source.midX - size.width / 2
            let desiredY = source.minY - size.height - 5
            let x = visible.map { max($0.minX, min(desiredX, $0.maxX - size.width)) } ?? desiredX
            let y = visible.map { max($0.minY, min(desiredY, $0.maxY - size.height)) } ?? desiredY

            let content = NSView(frame: CGRect(origin: .zero, size: size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
            content.layer?.cornerRadius = 10
            picker.setFrameOrigin(CGPoint(x: padding, y: padding))
            content.addSubview(picker)

            let panel = TodoCalendarPanel(contentRect: CGRect(origin: CGPoint(x: x, y: y), size: size),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.animationBehavior = .none
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.appearance = parent.appearance
            panel.level = parent.level
            panel.collectionBehavior = parent.collectionBehavior
            panel.sharingType = parent.sharingType
            panel.contentView = content
            self.panel = panel
            parent.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self, weak picker] in
                guard let self, let picker, picker.window === self.panel else { return }
                picker.target = self
                picker.action = #selector(Self.dateSelected(_:))
            }

            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak anchor] event in
                guard let self, let anchor, let owner = anchor.window as? BoringNotchSkyLightWindow,
                      event.window === owner, owner.isPointerOverPanel,
                      self.panel?.frame.contains(NSEvent.mouseLocation) != true else { return event }
                let clickedAnchor = anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                if !clickedAnchor { self.dismiss?() }
                return event
            }
        }

        func hide() {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            localMonitor = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.close()
                self.panel = nil
            }
        }

        @objc func dateSelected(_ picker: NSDatePicker) {
            select?(picker.dateValue)
        }
    }

}

final class TodoCalendarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct TodoDateHeaderLayout: Layout {
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let title = subviews.first else { return .zero }
        let size = title.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * expansion)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct TodoTitle: View, Animatable {
    let text: String
    var completionProgress: Double

    var animatableData: Double {
        get { completionProgress }
        set { completionProgress = newValue }
    }

    var body: some View {
        Text(text)
            .strikethrough(true, color: .white.opacity(0.55 * completionProgress))
            .foregroundStyle(.white.opacity(1 - 0.45 * completionProgress))
    }
}

private struct TodoRow<Content: View>: View, Equatable {
    let item: TodoItem
    let sectionDate: Date
    let isEditing: Bool
    let isConfirmingDeletion: Bool
    @State private var isHovered = false
    @ViewBuilder let content: (Bool) -> Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.sectionDate == rhs.sectionDate && lhs.isEditing == rhs.isEditing
            && lhs.isConfirmingDeletion == rhs.isConfirmingDeletion
    }

    var body: some View {
        content(isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
