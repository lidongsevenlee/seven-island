//
//  HooksActivityView.swift
//  boringNotch
//
//  Claude Code session list — shows sessions in the current project directory,
//  with live status (idle / working / blocked / ended).
//

import SwiftUI

struct HooksActivityView: View {
    @ObservedObject private var service = HooksActivityService.shared
    @EnvironmentObject private var vm: BoringViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 5) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Claude Code 会话")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(service.filteredSessions.count) 个项目")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    service.clearLog()
                } label: {
                    Text("清除")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)

            // ── Content ─────────────────────────────────────────────────────
            if service.filteredSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(service.filteredSessions) { session in
                            SessionCard(session: session)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 290)
            }
        }
        .padding(.bottom, 4)
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 10)
            Image(systemName: "person.slash")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("当前项目暂无 Claude Code 会话")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let cwd = service.currentProjectCwd {
                Text(cwd)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - SessionCard

private struct SessionCard: View {
    let session: HookSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: cwd name + status dot + status label | duration + model
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(session.cwdBasename)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                StatusDot(status: session.status)
                Text(session.status.label)
                    .font(.system(size: 10))
                    .foregroundStyle(statusTextColor)
                Spacer()
                Text(session.durationLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(session.modelShort)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Row 2: user prompt
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
                Text(session.lastUserPrompt ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Row 3: AI reply
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(session.lastAssistantMessage ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Row 4: notable event badges (only when present)
            if !session.notableEvents.isEmpty {
                HStack(spacing: 4) {
                    let permCount = session.notableEvents.filter { $0.event == "PermissionRequest" }.count
                    let notifCount = session.notableEvents.filter { $0.event == "Notification" }.count
                    let failCount = session.notableEvents.filter { $0.event == "StopFailure" }.count

                    if permCount > 0 {
                        NotableBadge(icon: "lock.shield", label: "\(permCount)", color: .orange)
                    }
                    if notifCount > 0 {
                        NotableBadge(icon: "bell.fill", label: "\(notifCount)", color: .pink)
                    }
                    if failCount > 0 {
                        NotableBadge(icon: "exclamationmark.triangle.fill", label: "\(failCount)", color: .red)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusTextColor: Color {
        switch session.status {
        case .idle:    return .green
        case .working: return .blue
        case .blocked: return .orange
        case .ended:   return .gray
        }
    }

    private var cardBackground: Color {
        switch session.status {
        case .idle:    return Color.white.opacity(0.07)
        case .working: return Color.blue.opacity(0.08)
        case .blocked: return Color.orange.opacity(0.08)
        case .ended:   return Color.white.opacity(0.04)
        }
    }
}

// MARK: - StatusDot

private struct StatusDot: View {
    let status: SessionStatus
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing ? 1.35 : 1.0)
            .opacity(pulsing ? 0.6 : 1.0)
            .onAppear {
                if status == .working {
                    withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                } else {
                    pulsing = false
                }
            }
            .onChange(of: status) { _, newStatus in
                if newStatus == .working {
                    withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        pulsing = false
                    }
                }
            }
    }

    private var dotColor: Color {
        switch status {
        case .idle:    return .green
        case .working: return .blue
        case .blocked: return .orange
        case .ended:   return .gray
        }
    }
}

// MARK: - NotableBadge

private struct NotableBadge: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}
