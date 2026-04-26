import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @EnvironmentObject private var vm: BoringViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // HStack {
            //     Spacer()
            //     HoverButton(icon: "trash", iconColor: .gray, scale: .medium) {
            //         store.clear()
            //     }
            //     .help("Clear clipboard history")
            // }
            // .frame(height: 18)

            if store.items.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: "Copy text or images to build history")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.items) { item in
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
        .help("Copy to clipboard")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }
}
