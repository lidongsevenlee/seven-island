import Defaults
import SwiftUI

struct AppLauncherSettingsView: View {
    @Default(.appLauncherExtraDirectories) private var extraDirectories

    var body: some View {
        Form {
            Section("默认目录") {
                ForEach(AppLauncherService.defaultApplicationDirectories, id: \.self) { directory in
                    directoryLabel(directory, title: directory.path == "/Applications" ? "应用程序" : "系统应用程序")
                }
            }
            Section("其他目录") {
                ForEach(extraDirectories, id: \.self) { directory in
                    HStack {
                        directoryLabel(directory)
                        Spacer()
                        Button {
                            extraDirectories.removeAll { $0 == directory }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除目录")
                        .help("从扫描目录移除")
                    }
                }
                Button {
                    addDirectories()
                } label: {
                    Label("添加目录…", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("App 快捷启动器")
    }

    private func directoryLabel(_ directory: URL, title: String? = nil) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                }
                Text((directory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
        }
    }

    private func addDirectories() {
        guard let window = SettingsWindowController.shared.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = AppLauncherService.defaultApplicationDirectories.first
        panel.message = "选择要扫描应用程序的目录"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let defaults = Set(AppLauncherService.applicationDirectories(adding: []))
            extraDirectories = AppLauncherService.applicationDirectories(adding: extraDirectories + panel.urls)
                .filter { !defaults.contains($0) }
        }
    }
}
