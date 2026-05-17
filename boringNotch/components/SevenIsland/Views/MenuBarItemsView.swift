import AppKit
import SwiftUI

struct MenuBarItemsView: View {
    @ObservedObject private var monitor = MenuBarItemMonitor.shared
    @EnvironmentObject private var vm: BoringViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !monitor.isAuthorized {
                PermissionRequiredView {
                    monitor.requestAuthorization()
                }
            } else if monitor.items.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: "当前没有被遮挡的菜单栏图标")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(42), spacing: 10), count: 10),
                        spacing: 10
                    ) {
                        ForEach(monitor.items) { item in
                            MenuBarItemButton(item: item) {
                                let clickLocation = NSEvent.mouseLocation
                                monitor.suspendRefreshForMenuInteraction()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    monitor.press(item, at: clickLocation)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onAppear {
            monitor.start(screenUUID: vm.screenUUID)
        }
        .onChange(of: vm.screenUUID) { _, screenUUID in
            monitor.updateScreen(screenUUID)
        }
        .onDisappear {
            monitor.stop()
        }
        .preferredColorScheme(.dark)
    }
}

private struct PermissionRequiredView: View {
    let onRequest: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            EmptyStateView(message: "需要辅助功能权限来读取菜单栏图标")
                .frame(maxWidth: .infinity)

            Button(action: onRequest) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open")
                    Text("授权辅助功能")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("打开 macOS 辅助功能授权提示")
        }
        .padding(.vertical, 14)
    }
}

private struct MenuBarItemButton: View {
    let item: MenuBarProxyItem
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 28, height: 28)
                .padding(7)
                .frame(width: 42, height: 42)
            .background(
                (isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .help(item.detail)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }

    @ViewBuilder
    private var icon: some View {
        if item.bundleIdentifier == "com.apple.systemuiserver" {
            if let menuBarImage = item.menuBarImage {
                Image(nsImage: menuBarImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.fallbackSystemImageName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else if let appIcon = item.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let menuBarImage = item.menuBarImage {
            Image(nsImage: menuBarImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: item.fallbackSystemImageName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
