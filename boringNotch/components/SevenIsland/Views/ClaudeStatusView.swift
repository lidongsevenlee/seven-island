import SwiftUI

struct ClaudeStatusView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var service = ClaudeStatusService.shared

    private func updateNotchHeight() {
        let count = service.snapshot.recentSessions.count
        let rowHeight: CGFloat = 40
        let spacing: CGFloat = 6
        let chrome: CGFloat = 50
        let contentHeight: CGFloat = count > 0
            ? CGFloat(count) * rowHeight + spacing * CGFloat(count - 1)
            : 88
        let height = min(contentHeight + chrome, sevenIslandFeatureNotchHeight)
        withAnimation(.smooth(duration: 0.24)) {
            vm.setOpenNotchHeight(height)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ScrollView(.vertical, showsIndicators: true) {
                    ClaudeSessionList(
                        sessions: service.snapshot.recentSessions,
                        onOpen: { session in
                            service.openClaude(session: session)
                        }
                    )
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 1)
        .onAppear { updateNotchHeight() }
        .onReceive(service.$snapshot) { _ in updateNotchHeight() }
        .task {
            service.refresh()
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            service.refresh()
        }
        .preferredColorScheme(.dark)
    }
}

private struct ClaudeSessionList: View {
    let sessions: [ClaudeSessionSummary]
    let onOpen: (ClaudeSessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sessions.isEmpty {
                ClaudeEmptySessionsView()
            } else {
                VStack(spacing: 6) {
                    ForEach(sessions) { session in
                        ClaudeSessionRow(
                            session: session,
                            onOpen: { onOpen(session) }
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClaudeEmptySessionsView: View {
    var body: some View {
        HStack(spacing: 8) {
            ClaudeGlyphIcon(size: 16, foreground: .secondary)
            Text("No local Claude sessions found")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSessionSummary
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ClaudeGlyphIcon(
                size: 18,
                foreground: session.activity?.state == .working ? Color.orange : Color.secondary
            )
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if session.activity?.state == .working {
                        Text("Working")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.orange)
                    }
                    if session.activity?.pendingAction != nil {
                        Text("Needs approval")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.yellow)
                    }
                }
                if let pending = session.activity?.pendingAction {
                    Text(pending.command ?? pending.toolName)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.yellow.opacity(0.85))
                        .lineLimit(1)
                } else {
                    Text(session.activity?.headline ?? "\(session.model ?? "model unknown")")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onOpen() }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isHovered ? 0.15 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(isHovered ? 0.15 : 0.06), lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovered = hovering
            }
        }
    }
}
