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
                EmptyStateView(message: "Copy text to build history")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.items) { item in
                            Button {
                                store.copyToPasteboard(item)
                                withAnimation(.smooth(duration: 0.2)) {
                                    vm.close()
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(item.preview)
                                        .font(.system(size: 12))
                                        .lineLimit(2)
                                        .foregroundStyle(.white)
                                    Spacer(minLength: 8)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")
                        }
                    }
                }
                .frame(maxHeight: 244)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .preferredColorScheme(.dark)
    }
}
