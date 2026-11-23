import Defaults
import SwiftUI

@MainActor
struct TodoView: View {
    private static let rowSpacing: CGFloat = 4

    struct Presentation: Hashable {
        let expansionCycle: Int
        let tabSelectionCycle: Int
    }

    let compactContentHeight: CGFloat
    let presentation: Presentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = TodoStore.shared
    @FocusState private var field: Field?
    @State private var filter: TodoFilter = .today
    @State private var historyDatesExpanded = true
    @State private var referenceDate = Date.now
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
    private var isCurrentPresentation: Bool {
        vm.notchState == .open && vm.coordinator.currentView == .todo
            && vm.expansionCycle == presentation.expansionCycle
            && vm.coordinator.tabSelectionCycle == presentation.tabSelectionCycle
    }

    private struct ListMeasurement: Equatable {
        let filter: TodoFilter
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
        let selection = filter
        let sections = store.sections(for: selection, on: referenceDate, in: calendar,
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
        let dates = store.dates(in: calendar)
        let minimumRowHeight = rowControlHeight + 2 * rowVerticalInset
        let rowCount = sections.reduce(0) { $0 + $1.items.count }
        // The panel can use its height cap once the minimum row heights fill it.
        let fillsAvailableHeight = rowCount > 0
            && CGFloat(rowCount) * minimumRowHeight >= maximumContentHeight - controlsHeight - spacing
        let panelHeight = preferredPanelHeight(rowCount: rowCount, fillsAvailableHeight: fillsAvailableHeight)

        VStack(alignment: .leading, spacing: spacing) {
            VStack(alignment: .leading, spacing: spacing) {
                composer
                filters(dates, in: calendar, todayHasItems: selection == .today ? rowCount > 0 : nil)
                if let pendingClear { clearConfirmation(pendingClear) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }

            if sections.isEmpty {
                EmptyStateView(message: filter == .today ? "今天还没有待办" : "这段时间没有待办")
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: ListMeasurement.self) { geometry in
                        ListMeasurement(filter: selection, rowCount: rowCount, height: geometry.size.height)
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
                            ListMeasurement(filter: selection, rowCount: rowCount, height: geometry.size.height)
                        } action: { measurement in
                            if !fillsAvailableHeight { listMeasurement = measurement }
                        }
                    }
                }
                .id(selection)
            }
        }
        .task(id: selection) {
            guard selection == .all, !historyDatesExpanded else { return }
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
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            referenceDate = .now
            if case .day = filter { selectFilter(.all) }
        }
        .onChange(of: dates) { _, dates in
            if case .day(let day) = filter, !dates.contains(day) { selectFilter(.all) }
        }
        .onChange(of: filter) { _, _ in
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
        guard let listMeasurement, listMeasurement.filter == filter, listMeasurement.rowCount == rowCount else { return nil }
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
        let canClearToday = todayHasItems ?? !store.items(matching: .today, on: referenceDate, in: calendar).isEmpty
        return HStack(spacing: 6) {
            filterButton(Text("今天"), for: .today, canClear: canClearToday)
            filterButton(Text("全部"), for: .all, canClear: !dates.isEmpty)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(dates, id: \.self) { date in
                        filterButton(dateLabel(date, in: calendar), for: .day(date), canClear: true)
                    }
                }
            }
        }
        .frame(height: 24)
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
        guard filter != selection else { return }
        if selection == .all { historyDatesExpanded = reduceMotion }
        filter = selection
    }

    private func requestClear(_ selection: TodoFilter) {
        let items = store.items(matching: selection, on: referenceDate, in: .autoupdatingCurrent)
        guard !items.isEmpty else { return }
        finishEdit()
        todoPendingDeletion = nil

        let scope: String
        switch selection {
        case .today:
            scope = "「今天」（含带入的历史待办）"
        case .all:
            scope = "「全部」"
        case .day(let date):
            scope = date.formatted(date: .abbreviated, time: .omitted)
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
                row(item, showsDate: filter == .today && !calendar.isDate(item.createdAt, inSameDayAs: referenceDate))
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.97))))
            }
        }
    }

    private func row(_ item: TodoItem, showsDate: Bool) -> some View {
        let isConfirmingDeletion = todoPendingDeletion == item.id
        return TodoRow(item: item, showsDate: showsDate, isEditing: editingID == item.id,
                       isConfirmingDeletion: isConfirmingDeletion) { isHovered in
            rowContent(item, showsDate: showsDate, isConfirmingDeletion: isConfirmingDeletion, isHovered: isHovered)
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
        _ item: TodoItem, showsDate: Bool, isConfirmingDeletion: Bool, isHovered: Bool
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
                        let selection = filter
                        let date = referenceDate
                        return { store.move(item.id, onto: target, in: selection, on: date, using: .autoupdatingCurrent) }
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
                timestamp(for: item, showsDate: showsDate)
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

    private func timestamp(for item: TodoItem, showsDate: Bool) -> some View {
        let time = showsDate ? Date.FormatStyle.dateTime.month(.defaultDigits).day().hour().minute() : .dateTime.hour().minute()
        let created = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        let label = item.completedAt.map { "创建于 \(created)\n完成于 \($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "创建于 \(created)"
        return Text(item.createdAt, format: time)
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
        selectFilter(.today)
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
    let showsDate: Bool
    let isEditing: Bool
    let isConfirmingDeletion: Bool
    @State private var isHovered = false
    @ViewBuilder let content: (Bool) -> Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.showsDate == rhs.showsDate && lhs.isEditing == rhs.isEditing
            && lhs.isConfirmingDeletion == rhs.isConfirmingDeletion
    }

    var body: some View {
        content(isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
