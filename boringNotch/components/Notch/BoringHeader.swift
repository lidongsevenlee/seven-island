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
    @ObservedObject var codexService = CodexStatusService.shared
    @ObservedObject var claudeService = ClaudeStatusService.shared
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
                        // Codex quick-access
                        let codexWorking = codexService.snapshot.currentActivity?.state == .working
                        let codexSelected = coordinator.currentView == .codexStatus
                        Button {
                            withAnimation(.smooth) {
                                coordinator.currentView = .codexStatus
                            }
                        } label: {
                            ZStack {
                                if codexSelected {
                                    Capsule()
                                        .fill(Color(nsColor: .secondarySystemFill))
                                }
                                CodexGlyphIcon(size: 15, foreground: codexWorking ? .green : codexSelected ? .white : .gray)
                            }
                            .frame(width: 32, height: 26)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(codexService.snapshot.currentActivity?.headline ?? "Codex")

                        // Claude quick-access
                        let claudeWorking = claudeService.snapshot.currentActivity?.state == .working
                        let claudeSelected = coordinator.currentView == .claudeStatus
                        Button {
                            withAnimation(.smooth) {
                                coordinator.currentView = .claudeStatus
                            }
                        } label: {
                            ZStack {
                                if claudeSelected {
                                    Capsule()
                                        .fill(Color(nsColor: .secondarySystemFill))
                                }
                                ClaudeGlyphIcon(size: 15, foreground: claudeWorking ? .orange : claudeSelected ? .white : .gray)
                            }
                            .frame(width: 32, height: 26)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(claudeService.snapshot.currentActivity?.headline ?? "Claude")

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
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }

                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .padding()
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
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
