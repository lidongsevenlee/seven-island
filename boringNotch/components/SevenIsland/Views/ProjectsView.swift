import Defaults
import SwiftUI

struct ProjectsView: View {
    @ObservedObject private var service = ProjectLauncherService.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Default(.vscodeProjectsDirectory) private var vscodeProjectsDirectory
    @Default(.projectOpenMethods) private var openMethods
    @Default(.projectDefaultOpenMethodID) private var defaultMethodID
    @State private var availableActions: [OpenAction] = []
    @State private var launchTask: Task<Void, Never>?
    @State private var launchError: String?

    private struct OpenAction: Identifiable {
        let method: ProjectOpenMethod
        let icon: NSImage?

        var id: ProjectOpenMethod.ID { method.id }
        var fallbackSymbol: String {
            switch method.kind {
            case .folder: "app"
            case .link: "link"
            case .command: "terminal"
            }
        }

        var image: Image {
            if let icon { Image(nsImage: icon) } else { Image(systemName: fallbackSymbol) }
        }
    }

    private var emptyMessage: String {
        guard service.projects.isEmpty else { return "没有匹配的项目" }
        let directory = vscodeProjectsDirectory.isEmpty ? "~/Projects" : vscodeProjectsDirectory
        return "\(directory) 中没有文件夹"
    }

    private var filteredProjects: [ProjectItem] {
        let query = vm.vscodeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty ? service.projects : service.projects.filter { $0.matches(query: query) }
    }

    var body: some View {
        let preferred = ProjectOpenMethod.preferred(in: openMethods, id: defaultMethodID)
        let alternatives = availableActions.filter { $0.id != preferred?.id }

        VStack(alignment: .leading, spacing: 8) {
            if let launchError {
                Text(launchError)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, sevenIslandRowInset)
            }
            SevenIslandLaunchList(
                searchText: $vm.vscodeSearchText,
                searchPrompt: "搜索项目...",
                items: filteredProjects,
                emptyMessage: emptyMessage,
                makesPanelKey: true,
                open: { open($0, with: preferred) }
            ) { project in
                SevenIslandLaunchRow(
                    title: project.name,
                    detail: project.detail,
                    help: preferred.map { "用\($0.title)打开" } ?? "打开项目",
                    open: { open(project, with: preferred) }
                ) {
                    Image(systemName: project.exists ? "folder" : "folder.badge.questionmark")
                        .foregroundStyle(project.exists ? Color.secondary : .orange)
                } actions: {
                    openButtons(for: project, actions: alternatives)
                }
            }
        }
        .onAppear { service.refresh() }
        .onChange(of: openMethods, initial: true) { _, methods in
            availableActions = methods.filter { ProjectLauncherService.isAvailable($0) }.map { method in
                OpenAction(method: method, icon: ProjectLauncherService.applicationIcon(for: method))
            }
        }
        .onDisappear { launchTask?.cancel() }
    }

    private func openButtons(for project: ProjectItem, actions: [OpenAction]) -> some View {
        let visibleCount = 3
        return HStack(spacing: 6) {
            ForEach(actions.prefix(visibleCount)) { action in
                let method = action.method
                ProjectAppIconButton(image: action.image, label: "用\(method.title)打开\(project.name)") {
                    open(project, with: method)
                }
            }

            if actions.count > visibleCount {
                Menu {
                    ForEach(actions.dropFirst(visibleCount)) { action in
                        Button {
                            open(project, with: action.method)
                        } label: {
                            Label { Text(action.method.title) } icon: { action.image }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多打开方式")
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func open(_ project: ProjectItem, with method: ProjectOpenMethod?) {
        guard launchTask == nil else { return }
        guard let method else {
            launchError = "请在「设置 → 项目」添加打开方式。"
            return
        }
        launchError = nil
        launchTask = Task {
            defer { launchTask = nil }
            do {
                try await service.open(project, with: method)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) { vm.closeUnlessPinned() }
            } catch {
                guard !Task.isCancelled else { return }
                launchError = (error as? ProjectLauncherService.LaunchError)?.localizedDescription
                    ?? "无法用\(method.title)打开「\(project.name)」。"
            }
        }
    }
}

private struct ProjectAppIconButton: View {
    let image: Image
    let label: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 26, height: 26)
                .background(.white.opacity(isHovering ? 0.20 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        }
        .buttonStyle(ScaleButtonStyle())
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
