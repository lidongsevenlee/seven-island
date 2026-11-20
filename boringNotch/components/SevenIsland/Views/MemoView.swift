import SwiftUI

@MainActor
struct MemoView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = MemoStore.shared
    @FocusState private var isEditorFocused: Bool
    @State private var memoPendingDeletion: UUID?
    @State private var hoveredMemoID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(store.library.items) { memo in
                                MemoTab(
                                    memo: memo,
                                    isSelected: store.library.selectedID == memo.id,
                                    isConfirmingDeletion: memoPendingDeletion == memo.id,
                                    isHovered: hoveredMemoID == memo.id,
                                    select: {
                                        memoPendingDeletion = nil
                                        store.selectMemo(id: memo.id)
                                    },
                                    delete: { deleteOrConfirm(memo) }
                                )
                                .id(memo.id)
                                .onHover { hovering in
                                    if hovering {
                                        hoveredMemoID = memo.id
                                    } else if hoveredMemoID == memo.id {
                                        hoveredMemoID = nil
                                    }
                                }
                            }
                        }
                        .animation(.easeInOut(duration: 0.15), value: hoveredMemoID)
                        .animation(.easeInOut(duration: 0.15), value: memoPendingDeletion)
                    }
                    .onChange(of: store.library.selectedID, initial: true) { _, id in
                        if let id {
                            proxy.scrollTo(id, anchor: .trailing)
                        }
                    }
                }

                Button {
                    memoPendingDeletion = nil
                    store.createMemo()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .offset(x: 2) // Account for the symbol's trailing inset.
                        .frame(width: 28, height: 28, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("新建备忘录")
                .accessibilityLabel("新建备忘录")
            }
            .frame(height: 28)

            if let memo = store.selectedMemo {
                editor(for: memo)
                    .id(memo.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 24))
                    Text("点击右侧 + 创建备忘录")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: store.library.selectedID) {
            isEditorFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            isEditorFocused = store.selectedMemo != nil
        }
        .onChange(of: isEditorFocused) { _, focused in
            vm.isTextInputFocused = focused
        }
        .onChange(of: store.library.selectedID) { _, _ in
            memoPendingDeletion = nil
        }
        .onDisappear {
            vm.isTextInputFocused = false
            memoPendingDeletion = nil
            hoveredMemoID = nil
        }
        .preferredColorScheme(.dark)
    }

    private func deleteOrConfirm(_ memo: MemoItem) {
        if memoPendingDeletion == memo.id {
            store.deleteMemo(id: memo.id)
            memoPendingDeletion = nil
        } else {
            memoPendingDeletion = memo.id
        }
    }

    private func editor(for memo: MemoItem) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { store.memo(id: memo.id)?.text ?? "" },
                set: { store.updateText($0, for: memo.id) }
            ))
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .focused($isEditorFocused)
            .accessibilityLabel("备忘录内容")
            .accessibilityHint("内容自动保存在本机")

            if memo.text.isEmpty {
                Text("记下待办、想法或临时内容…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 8))
        .simultaneousGesture(TapGesture().onEnded {
            memoPendingDeletion = nil
        })
    }
}

private struct MemoTab: View {
    let memo: MemoItem
    let isSelected: Bool
    let isConfirmingDeletion: Bool
    let isHovered: Bool
    let select: () -> Void
    let delete: () -> Void

    private var showsDeleteButton: Bool {
        isHovered || isConfirmingDeletion
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                Text(memo.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 9)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: Text(isConfirmingDeletion ? "确认删除备忘录" : "删除备忘录"), delete)

            if showsDeleteButton {
                InlineDeleteButton(
                    itemTitle: memo.title,
                    deleteLabel: "删除备忘录",
                    isConfirming: isConfirmingDeletion,
                    color: isSelected ? .white : .secondary,
                    action: delete
                )
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.24).delay(0.12)),
                    removal: .opacity.animation(.easeOut(duration: 0.08))
                ))
            }
        }
        .padding(.trailing, showsDeleteButton ? 5 : 9)
        .foregroundStyle(isSelected ? .white : .secondary)
        .background(
            isSelected ? sevenIslandContentBackground : Color.white.opacity(isHovered ? 0.09 : 0.04),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
}

struct InlineDeleteButton: View {
    let itemTitle: String
    let deleteLabel: String
    let isConfirming: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .semibold))

                if isConfirming {
                    Text("?")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 3)
            .frame(minWidth: 18, minHeight: 18)
            .foregroundStyle(isConfirming ? .red : color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isConfirming ? "再次点击\(deleteLabel)" : deleteLabel)
        .accessibilityLabel(isConfirming ? "确认删除\(itemTitle)？" : "删除\(itemTitle)")
    }
}
