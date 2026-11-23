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
    @State private var isLockHovered = false
    @State private var isSettingsHovered = false
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if coordinator.alwaysShowTabs {
                    TabSelectionView(tabs: coordinator.tabLayout.leadingTabs)
                        .padding(.leading, 2)
                        .padding(.trailing, 12)
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
                    .fill(vm.display?.hasPhysicalNotch == true ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if coordinator.alwaysShowTabs {
                        TabSelectionView(tabs: coordinator.tabLayout.trailingTabs)
                    }
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
                        panelLockToggle
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
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: "gearshape.fill")
                                                    .font(.system(size: 6, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .frame(width: 8, height: 8)
                                                    .background(.black, in: Circle())
                                            }
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .accessibilityLabel("设置")
                            .onHover { hovering in
                                isSettingsHovered = hovering
                            }
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .padding(.trailing, sevenIslandHeaderTrailingInset)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    private var panelLockToggle: some View {
        Toggle(isOn: $vm.isPinnedOpen) {
            NotchHeaderSymbol(name: vm.isPinnedOpen ? "lock.fill" : "lock.open")
                .foregroundStyle(.white.opacity(vm.isPinnedOpen || isLockHovered ? 0.98 : 0.72))
                .frame(width: 24, height: 24)
                .background {
                    Capsule()
                        .fill(Color(nsColor: .secondarySystemFill))
                        .opacity(vm.isPinnedOpen || isLockHovered ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("面板常驻")
        .help(vm.isPinnedOpen ? "取消面板常驻" : "保持面板常驻")
        .onHover { isLockHovered = $0 }
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
