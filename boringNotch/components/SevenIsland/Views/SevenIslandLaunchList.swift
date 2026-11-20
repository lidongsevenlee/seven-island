import SwiftUI

struct SevenIslandLaunchList<Item: Identifiable, Row: View>: View {
    @Binding var searchText: String
    let searchPrompt: String
    let items: [Item]
    let emptyMessage: String
    var makesPanelKey = false
    let open: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    @EnvironmentObject private var vm: BoringViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: sevenIslandRowSpacing) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(width: sevenIslandRowIconWidth)
                TextField(searchPrompt, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if let first = items.first {
                            open(first)
                        }
                    }
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
            .padding(.horizontal, sevenIslandRowInset)
            .padding(.vertical, 6)
            .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 8))

            if items.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: emptyMessage)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items, content: row)
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .task(id: vm.notchState) {
            guard vm.notchState == .open else { return }
            isSearchFocused = false
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, vm.notchState == .open else { return }
            if makesPanelKey {
                vm.makePanelKeyForKeyboardInput()
            }
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
}

struct SevenIslandLaunchRow<Icon: View, Actions: View>: View {
    let title: String
    let detail: String?
    let help: String
    let open: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let actions: () -> Actions

    @State private var isHovering = false
    @State private var didPushCursor = false

    var body: some View {
        HStack(spacing: sevenIslandRowSpacing) {
            Button(action: open) {
                HStack(spacing: sevenIslandRowSpacing) {
                    icon()
                        .frame(width: sevenIslandRowIconWidth)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let detail {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, sevenIslandRowInset)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            actions()
        }
        .padding(.trailing, sevenIslandRowInset)
        .background(
            isHovering ? sevenIslandHoveredContentBackground : sevenIslandContentBackground,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            if hovering && !didPushCursor {
                NSCursor.pointingHand.push()
                didPushCursor = true
            } else if !hovering {
                resetCursor()
            }
        }
        .onDisappear(perform: resetCursor)
    }

    private func resetCursor() {
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }
}
