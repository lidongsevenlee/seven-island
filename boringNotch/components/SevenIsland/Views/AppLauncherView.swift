import Defaults
import SwiftUI

struct AppLauncherView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @Default(.appLauncherExtraDirectories) private var extraDirectories
    @State private var applications: [AppLauncherItem] = []
    @State private var isScanning = true
    @State private var launchTask: Task<Void, Never>?
    @State private var launchError: String?

    private var filteredApplications: [AppLauncherItem] {
        let query = vm.appLauncherSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? applications : applications.filter { $0.matches(query: query) }
    }

    private var emptyMessage: String {
        if isScanning { return "正在查找应用…" }
        if applications.isEmpty { return "扫描目录中没有应用程序" }
        return "没有匹配的应用"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let launchError {
                Text(launchError)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, sevenIslandRowInset)
            }
            SevenIslandLaunchList(
                searchText: $vm.appLauncherSearchText,
                searchPrompt: "搜索应用...",
                items: filteredApplications,
                emptyMessage: emptyMessage,
                makesPanelKey: true,
                open: open
            ) { item in
                SevenIslandLaunchRow(title: item.name, detail: nil, help: "打开应用程序", open: { open(item) }) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(height: 18)
                } actions: {
                    EmptyView()
                }
            }
        }
        .task(id: extraDirectories) { await refresh(adding: extraDirectories) }
        .onDisappear { launchTask?.cancel() }
    }

    private func refresh(adding extraDirectories: [URL]) async {
        isScanning = true
        let scan = Task.detached(priority: .userInitiated) {
            let directories = AppLauncherService.applicationDirectories(adding: extraDirectories)
            return AppLauncherService.loadApplications(from: directories)
        }
        let results = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled else { return }
        applications = results
        isScanning = false
    }

    private func open(_ item: AppLauncherItem) {
        guard launchTask == nil else { return }
        launchError = nil
        launchTask = Task {
            defer { launchTask = nil }
            do {
                try await AppLauncherService.openApplication(item)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    vm.closeUnlessPinned()
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let error = error as? AppLauncherService.JavaLaunchError {
                    launchError = error.localizedDescription
                } else {
                    launchError = "无法打开「\(item.name)」"
                }
            }
        }
    }
}
