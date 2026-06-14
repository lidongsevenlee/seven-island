//
//  ClaudeHookNotificationView.swift
//  boringNotch
//
//  Compact notification in the closed notch for Claude Code session events.
//  - blocked: shows permission details + Allow / Deny / custom-reason buttons
//  - idle (completed): shows a simple "done" banner
//

import SwiftUI

/// Lightweight state holder shared between AppDelegate callback and the view.
@MainActor
final class ClaudeHookNotificationState: ObservableObject {
    static let shared = ClaudeHookNotificationState()
    @Published var label: String = ""
    @Published var isBlocked: Bool = false
    private init() {}
}

// MARK: - Heights

/// Notch bar height when showing a "done" notification
let claudeHookIdleHeight: CGFloat   = 52
/// Notch bar height when showing a permission request with buttons
let claudeHookBlockedHeight: CGFloat = 88

// MARK: - Main view

struct ClaudeHookNotificationView: View {
    @ObservedObject private var state   = ClaudeHookNotificationState.shared
    @ObservedObject private var server  = AgentSocketServer.shared
    @State private var denyReason: String = ""
    @State private var showReasonField: Bool = false
    @State private var isDismissing: Bool = false
    @FocusState private var reasonFocused: Bool

    var body: some View {
        if state.isBlocked, let req = server.pendingPermission {
            permissionBanner(req)
        } else {
            doneBanner
        }
    }

    // MARK: - Done banner

    private var doneBanner: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                Text(state.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(.black).frame(width: 130)

            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Claude Code")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Permission banner

    @ViewBuilder
    private func permissionBanner(_ req: PermissionRequest) -> some View {
        HStack(spacing: 0) {
            // Left: info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("\(req.cwdBasename) · \(req.toolName)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if !req.description.isEmpty {
                    Text(req.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if showReasonField {
                    TextField("拒绝原因…", text: $denyReason)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .focused($reasonFocused)
                        .onSubmit { submitDeny() }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Notch spacer
            Rectangle().fill(.black).frame(width: 130)

            // Right: action buttons
            HStack(spacing: 6) {
                // Allow
                Button {
                    server.allow()
                    dismiss()
                } label: {
                    Label("允许", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("允许此操作")

                // Deny / input reason
                if showReasonField {
                    Button {
                        submitDeny()
                    } label: {
                        Label("发送", systemImage: "return")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        withAnimation(.smooth(duration: 0.15)) {
                            showReasonField = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            reasonFocused = true
                        }
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("拒绝此操作（可输入原因）")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func submitDeny() {
        guard !isDismissing else { return }
        server.deny(reason: denyReason)
        dismiss()
    }

    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        denyReason = ""
        showReasonField = false
        // Set isBlocked = false first, then hide — both synchronously on MainActor
        // so didSet evaluates the correct state and doesn't restart the timer
        ClaudeHookNotificationState.shared.isBlocked = false
        withAnimation(.smooth) {
            BoringViewCoordinator.shared.expandingView.show = false
        }
    }
}
