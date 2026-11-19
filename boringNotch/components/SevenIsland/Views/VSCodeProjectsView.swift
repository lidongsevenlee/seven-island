import Defaults
import SwiftUI

struct VSCodeProjectsView: View {
    @ObservedObject private var service = VSCodeRecentProjectsService.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Default(.vscodeProjectsDirectory) private var vscodeProjectsDirectory
    @FocusState private var isSearchFocused: Bool

    private var emptyMessage: String {
        if vscodeProjectsDirectory.isEmpty {
            return "~/Projects 中没有文件夹"
        }
        return "\(vscodeProjectsDirectory) 中没有文件夹"
    }
    private var filteredProjects: [VSCodeProjectItem] {
        guard !vm.vscodeSearchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return service.projects
        }
        let query = vm.vscodeSearchText.lowercased()
        return service.projects
            .filter { $0.matches(query: query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: sevenIslandRowSpacing) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(width: sevenIslandRowIconWidth)
                TextField("搜索项目...", text: $vm.vscodeSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .focused($isSearchFocused)
                    .onSubmit {
                        guard let first = filteredProjects.first else { return }
                        service.open(first)
                        withAnimation(.smooth(duration: 0.2)) {
                            vm.close()
                        }
                    }
                if !vm.vscodeSearchText.isEmpty {
                    Button {
                        vm.vscodeSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, sevenIslandRowInset)
            .padding(.vertical, 6)
            .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 8))

            if service.projects.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: emptyMessage)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else if filteredProjects.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: "没有匹配的项目")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredProjects) { project in
                            Button {
                                service.open(project)
                                withAnimation(.smooth(duration: 0.2)) {
                                    vm.close()
                                }
                            } label: {
                                VSCodeProjectRow(project: project)
                            }
                            .buttonStyle(.plain)
                            .help("在新的 VS Code 窗口中打开")
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .onAppear {
            service.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isSearchFocused = true
            }
        }
        .onChange(of: isSearchFocused) { _, focused in
            vm.isTextInputFocused = focused
        }
        .onDisappear {
            vm.isTextInputFocused = false
        }
        .preferredColorScheme(.dark)
    }
}

private struct VSCodeProjectRow: View {
    let project: VSCodeProjectItem

    @State private var isHovering = false
    @State private var didPushCursor = false

    private var iconName: String {
        project.exists ? "folder" : "folder.badge.questionmark"
    }

    private var iconColor: Color {
        project.exists ? .secondary : .orange
    }

    var body: some View {
        HStack(spacing: sevenIslandRowSpacing) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: sevenIslandRowIconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(project.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, sevenIslandRowInset)
        .padding(.vertical, 7)
        .background(
            isHovering ? sevenIslandHoveredContentBackground : sevenIslandContentBackground,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            // Balanced NSCursor.push/pop — see ClipboardItemRow for rationale.
            if hovering {
                if !didPushCursor {
                    NSCursor.pointingHand.push()
                    didPushCursor = true
                }
            } else if didPushCursor {
                NSCursor.pop()
                didPushCursor = false
            }
        }
        .onDisappear {
            if didPushCursor {
                NSCursor.pop()
                didPushCursor = false
            }
        }
    }
}
