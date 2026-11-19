import Defaults
import SwiftUI

struct VSCodeProjectsView: View {
    @ObservedObject private var service = VSCodeRecentProjectsService.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Default(.vscodeProjectsDirectory) private var vscodeProjectsDirectory

    private var emptyMessage: String {
        guard service.projects.isEmpty else { return "没有匹配的项目" }
        let directory = vscodeProjectsDirectory.isEmpty ? "~/Projects" : vscodeProjectsDirectory
        return "\(directory) 中没有文件夹"
    }

    private var filteredProjects: [VSCodeProjectItem] {
        guard !vm.vscodeSearchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return service.projects
        }
        let query = vm.vscodeSearchText.lowercased()
        return service.projects.filter { $0.matches(query: query) }
    }

    var body: some View {
        SevenIslandLaunchList(
            searchText: $vm.vscodeSearchText,
            searchPrompt: "搜索项目...",
            items: filteredProjects,
            emptyMessage: emptyMessage,
            itemHelp: "在新的 VS Code 窗口中打开",
            open: open
        ) { project in
            SevenIslandLaunchRow(title: project.name, detail: project.detail) {
                Image(systemName: project.exists ? "folder" : "folder.badge.questionmark")
                    .foregroundStyle(project.exists ? Color.secondary : .orange)
            }
        }
        .onAppear { service.refresh() }
    }

    private func open(_ project: VSCodeProjectItem) {
        service.open(project)
        withAnimation(.smooth(duration: 0.2)) {
            vm.closeUnlessPinned()
        }
    }
}
