//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @State private var isSettingsHovered = false
    @State private var isClaudeHovered = false
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if !tvm.isEmpty || coordinator.alwaysShowTabs {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.showMirror] {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        // Agent (Claude / Codex / OpenCode) tab
                        Button(action: {
                            coordinator.currentView = .hooksActivity
                        }) {
                            Capsule()
                                .fill(Color(nsColor: .secondarySystemFill).opacity(isClaudeHovered || coordinator.currentView == .hooksActivity ? 1 : 0))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(
                                            coordinator.currentView == .hooksActivity
                                            ? .white
                                            : .gray.opacity(isClaudeHovered ? 0.98 : 0.82)
                                        )
                                        .font(.system(size: 12, weight: .medium))
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Agent 会话")
                        .onHover { hovering in
                            isClaudeHovered = hovering
                        }

                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                            }) {
                                Capsule()
                                    .fill(Color(nsColor: .secondarySystemFill).opacity(isSettingsHovered ? 1 : 0))
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        Image("logo2")
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 16, height: 16)
                                            .opacity(isSettingsHovered ? 0.98 : 0.82)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .onHover { hovering in
                                isSettingsHovered = hovering
                            }
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
