import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @EnvironmentObject private var vm: BoringViewModel
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [ClipboardHistoryItem] {
        let query = vm.clipboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.items.filter { item in
            (vm.clipboardFilter == nil || item.kind == vm.clipboardFilter) && item.matches(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                categoryButton("全部", kind: nil)
                ForEach(ClipboardHistoryItem.Kind.allCases, id: \.self) { kind in
                    categoryButton(kind.rawValue, kind: kind)
                }
            }

            HStack(spacing: sevenIslandRowSpacing) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(width: sevenIslandRowIconWidth)
                TextField("搜索剪贴板历史...", text: $vm.clipboardSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .focused($isSearchFocused)
                if !vm.clipboardSearchText.isEmpty {
                    Button {
                        vm.clipboardSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, sevenIslandRowInset)
            .padding(.vertical, 6)
            .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 8))

            if store.items.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: "复制文本、图片或文件以构建历史")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else if filteredItems.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: "没有匹配的项目")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredItems) { item in
                            ClipboardItemRow(item: item) {
                                store.copyToPasteboard(item)
                                withAnimation(.smooth(duration: 0.2)) {
                                    vm.closeUnlessPinned()
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            isSearchFocused = true
        }
        .onChange(of: isSearchFocused) { _, focused in
            vm.isTextInputFocused = focused
        }
        .onDisappear {
            vm.isTextInputFocused = false
        }
        .preferredColorScheme(.dark)
    }

    private func categoryButton(_ label: String, kind: ClipboardHistoryItem.Kind?) -> some View {
        let selected = vm.clipboardFilter == kind
        return Button {
            vm.clipboardFilter = kind
        } label: {
            Text(label)
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
    }
}

private struct ClipboardItemRow: View {
    let item: ClipboardHistoryItem
    let onCopy: () -> Void

    @State private var isHovering = false
    @State private var didPushCursor = false
    @State private var cachedImage: NSImage?

    private var icon: String {
        switch item.kind {
        case .text: "doc.on.doc"
        case .image: "photo"
        case .files: "folder"
        }
    }

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: sevenIslandRowSpacing) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: sevenIslandRowIconWidth)

                if item.isImage {
                    if let nsImage = cachedImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                } else {
                    Text(item.content ?? item.preview)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, sevenIslandRowInset)
            .padding(.vertical, 8)
            .background(
                isHovering ? sevenIslandHoveredContentBackground : sevenIslandContentBackground,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .help("复制到剪贴板")
        .task(id: item.id) {
            // Decode PNG only once per row appearance, not on every body eval.
            guard item.isImage, let data = item.imageData else { return }
            let decoded = NSImage(data: data)
            await MainActor.run { cachedImage = decoded }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            // Pair NSCursor.push() with exactly one pop() per row. SwiftUI may
            // deliver an unbalanced trailing `false` during scroll / view
            // teardown — without the guard the cursor stack drifts and the
            // pointing hand cursor gets stuck system-wide.
            if hovering {
                if !didPushCursor {
                    NSCursor.pointingHand.push()
                    didPushCursor = true
                }
            } else if didPushCursor {
                NSCursor.pop()
                didPushCursor = false
            }
        }
        .onDisappear {
            if didPushCursor {
                NSCursor.pop()
                didPushCursor = false
            }
        }
    }
}
