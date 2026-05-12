//
//  OnboardingView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI

enum OnboardingStep {
    case welcome
    case accessibilityPermission
    case musicPermission
    case finished
}

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        step = .accessibilityPermission
                    }
                }
                .transition(.opacity)

            case .accessibilityPermission:
                PermissionRequestView(
                    icon: Image(systemName: "hand.raised.fill"),
                    title: "启用辅助功能权限",
                    description: "需要辅助功能权限才能用 Seven Island HUD 替换系统通知。这将允许应用拦截媒体和亮度事件以显示自定义 HUD 覆盖层。",
                    privacyNote: "辅助功能权限仅用于改善媒体和亮度通知。不会收集或分享任何数据。",
                    onAllow: {
                        Task {
                            await requestAccessibilityPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(.opacity)

            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            BoringViewCoordinator.shared.firstLaunch = false
                            step = .finished
                        }
                    }
                )
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
            }
        }
        .frame(width: 400, height: 600)
    }

    // MARK: - Permission Request Logic

    func requestAccessibilityPermission() async {
        await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
    }
}
