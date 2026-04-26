import SwiftUI

struct CodexStatusView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var service = CodexStatusService.shared
    @State private var selectedSessionID: CodexSessionSummary.ID?

    private var sessionListHeight: CGFloat {
        max(
            CodexStatusLayout.minimumListHeight,
            targetNotchHeight - CodexStatusLayout.notchChromeHeight
        )
    }

    private var targetNotchHeight: CGFloat {
        selectedSessionID == nil ? sevenIslandFeatureNotchHeight : codexExpandedNotchHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                CodexSessionList(
                    sessions: service.snapshot.recentSessions,
                    selectedSessionID: selectedSessionID,
                    snapshot: service.snapshot,
                    onSelect: { session in
                        withAnimation(.smooth(duration: 0.24)) {
                            selectedSessionID = selectedSessionID == session.id ? nil : session.id
                        }
                    },
                    onOpen: { session in
                        service.openCodex(session: session)
                    }
                )
            }
            .frame(height: sessionListHeight)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 1)
        .onAppear {
            service.refresh()
        }
        .onChange(of: selectedSessionID) { _, selectedSessionID in
            updateNotchHeight(hasExpandedDetail: selectedSessionID != nil)
        }
        .onChange(of: service.snapshot.recentSessions) { _, sessions in
            if selectedSessionID != nil && !sessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = nil
            }
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            service.refresh()
        }
        .preferredColorScheme(.dark)
    }

    private func updateNotchHeight(hasExpandedDetail: Bool) {
        withAnimation(.smooth(duration: 0.24)) {
            vm.setOpenNotchHeight(hasExpandedDetail ? codexExpandedNotchHeight : sevenIslandFeatureNotchHeight)
        }
    }
}

private enum CodexStatusLayout {
    static let minimumListHeight: CGFloat = 158 * 1.5
    static let notchChromeHeight: CGFloat = 102
}

private struct CodexSessionList: View {
    let sessions: [CodexSessionSummary]
    let selectedSessionID: CodexSessionSummary.ID?
    let snapshot: CodexStatusSnapshot
    let onSelect: (CodexSessionSummary) -> Void
    let onOpen: (CodexSessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sessions.isEmpty {
                CodexEmptySessionsView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sessions) { session in
                            VStack(spacing: 6) {
                                CodexSessionRow(
                                    session: session,
                                    isSelected: session.id == selectedSessionID,
                                    onSelect: { onSelect(session) },
                                    onOpen: { onOpen(session) }
                                )

                                if session.id == selectedSessionID {
                                    CodexSessionDetail(session: session, snapshot: snapshot)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodexEmptySessionsView: View {
    var body: some View {
        HStack(spacing: 8) {
            CodexGlyphIcon(size: 16, foreground: .secondary)
            Text("No local Codex sessions found")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CodexSessionDetail: View {
    let session: CodexSessionSummary?
    let snapshot: CodexStatusSnapshot

    var body: some View {
        Group {
            if let session {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(session.activity?.stateDisplayText ?? "Idle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(session.activity?.state == .working ? Color.green : Color.secondary)
                        if let tool = session.activity?.lastToolName {
                            Text(tool)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.86))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.1), in: Capsule())
                        }
                    }

                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(session.activity?.headline ?? "No recent activity")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)

                    if let lastTurn = session.lastTurn {
                        CodexLastTurnView(turn: lastTurn)
                    } else {
                        Text(session.activity?.detail ?? session.cwd)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        CodexDetailChip(text: "\(session.tokensDisplayText) tokens")
                        CodexDetailChip(text: session.model ?? "model unknown")
                        CodexDetailChip(text: session.reasoningEffort ?? "effort unknown")
                    }

                    HStack(spacing: 6) {
                        CodexDetailChip(text: session.activity?.primaryLimitDisplayText ?? "Primary unknown")
                        CodexDetailChip(text: session.activity?.secondaryLimitDisplayText ?? "Weekly unknown")
                        CodexDetailChip(text: snapshot.authorizationDisplayText)
                    }

                    Text(session.cwd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            } else {
                CodexEmptySessionsView()
            }
        }
    }
}

private struct CodexLastTurnView: View {
    let turn: CodexConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let userText = turn.userText, !userText.isEmpty {
                CodexTurnText(label: "You", text: userText, lineLimit: 3)
            }
            if let assistantText = turn.assistantText, !assistantText.isEmpty {
                CodexTurnText(label: "Codex", text: assistantText, lineLimit: 4)
            }
        }
    }
}

private struct CodexTurnText: View {
    let label: String
    let text: String
    let lineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.green.opacity(0.9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CodexDetailChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08), in: Capsule())
    }
}

private struct CodexAgentCard: View {
    let snapshot: CodexStatusSnapshot

    private var activity: CodexWorkActivity? {
        snapshot.currentActivity
    }

    private var isWorking: Bool {
        activity?.state == .working
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isWorking ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(isWorking ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(activity?.stateDisplayText ?? "Idle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isWorking ? Color.green : Color.secondary)
                    if let tool = activity?.lastToolName {
                        Text(tool)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.1), in: Capsule())
                    }
                }

                Text(activity?.headline ?? "Codex is ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(activity?.detail ?? "Open Codex to start or inspect a session")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(snapshot.totalTokensDisplayText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(snapshot.codexAppVersion.map { "App \($0)" } ?? snapshot.codexCLIStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isWorking ? Color.green.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct CodexMetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CodexSessionRow: View {
    let session: CodexSessionSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    CodexGlyphIcon(
                        size: 18,
                        foreground: session.activity?.state == .working ? Color.green : Color.secondary
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
                                    .foregroundStyle(Color.green)
                            }
                        }
                        Text(session.activity?.headline ?? "\(session.tokensDisplayText) tokens · \(session.model ?? "model unknown")")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            HoverButton(icon: "arrow.up.forward.app", iconColor: .gray, scale: .medium, action: onOpen)
                .help("Open this Codex session")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            (isSelected ? Color.green.opacity(0.13) : (isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.08))),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.green.opacity(0.35) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }
}
