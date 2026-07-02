//
//  HooksActivityView.swift
//  boringNotch
//
//  Claude Code / Codex session list — shows sessions grouped by agent,
//  with live status (idle / working / blocked / ended).
//

import SwiftUI

struct HooksActivityView: View {
    @ObservedObject private var service = HooksActivityService.shared
    @EnvironmentObject private var vm: BoringViewModel

    @State private var activeFilter: SessionFilter = .all

    private enum SessionFilter: String, CaseIterable, Identifiable {
        case all, claude, codex, opencode
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:      return "全部"
            case .claude:   return "Claude"
            case .codex:    return "Codex"
            case .opencode: return "OpenCode"
            }
        }
    }

    private var filteredSessions: [HookSession] {
        switch activeFilter {
        case .all:      return service.filteredSessions
        case .claude:   return service.filteredSessions.filter { $0.platform == .claude }
        case .codex:    return service.filteredSessions.filter { $0.platform == .codex }
        case .opencode: return service.filteredSessions.filter { $0.platform == .opencode }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Agent 会话")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(filteredSessions.count) 个")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    service.clearLog()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除日志")
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)

            // ── Filter pills ───────────────────────────────────────────────
            HStack(spacing: 6) {
                ForEach(SessionFilter.allCases) { filter in
                    filterPill(filter)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            // ── Content ─────────────────────────────────────────────────────
            if filteredSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filteredSessions) { session in
                            SessionCard(session: session)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(.bottom, 4)
        .preferredColorScheme(.dark)
    }

    // MARK: - Filter pill

    @ViewBuilder
    private func filterPill(_ filter: SessionFilter) -> some View {
        let isActive = activeFilter == filter
        let count: Int = {
            switch filter {
            case .all:      return service.filteredSessions.count
            case .claude:   return service.filteredSessions.filter { $0.platform == .claude }.count
            case .codex:    return service.filteredSessions.filter { $0.platform == .codex }.count
            case .opencode: return service.filteredSessions.filter { $0.platform == .opencode }.count
            }
        }()
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { activeFilter = filter }
        } label: {
            HStack(spacing: 3) {
                Text(filter.label)
                    .font(.system(size: 10, weight: .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9))
                        .foregroundStyle(isActive ? Color.white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isActive ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                in: Capsule()
            )
            .foregroundStyle(isActive ? Color.white : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 10)
            Image(systemName: "person.slash")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("当前项目暂无 Agent 会话")
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
            // Row 1: platform brand Shape + cwd name + status dot + status label | duration + model
            HStack(spacing: 5) {
                // Platform brand glyph in its accent color
                session.platform.brandIconShape
                    .fill(platformAccent)
                    .frame(width: 11, height: 11)
                    .frame(width: 12, alignment: .center)
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

            // Row 3: AI reply — platform brand Shape variant with darker fill
            HStack(spacing: 4) {
                session.platform.brandIconShape
                    .fill(platformAccent.opacity(0.7))
                    .frame(width: 9, height: 9)
                    .frame(width: 12, alignment: .center)
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
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(platformAccent.opacity(0.18), lineWidth: 0.6)
        )
    }

    // Brand-derived accent for each platform
    private var platformAccent: Color {
        let rgb = session.platform.brandColorRGB
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
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
        case .working: return platformAccent.opacity(0.10)
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
