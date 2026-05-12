import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @EnvironmentObject private var vm: BoringViewModel
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [ClipboardHistoryItem] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return store.items
        }
        let query = searchText.lowercased()
        return store.items.filter { item in
            if item.isImage {
                return false
            }
            return item.content?.lowercased().contains(query) ?? false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("搜索剪贴板历史...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if store.items.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: "复制文本或图片以构建历史")
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
                                    vm.close()
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .preferredColorScheme(.dark)
    }
}

private struct ClipboardItemRow: View {
    let item: ClipboardHistoryItem
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 10) {
                Image(systemName: item.isImage ? "photo" : "doc.on.doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                if item.isImage {
                    if let data = item.imageData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                } else if let text = item.content {
                    Text(text)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                (isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .help("复制到剪贴板")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }
}
