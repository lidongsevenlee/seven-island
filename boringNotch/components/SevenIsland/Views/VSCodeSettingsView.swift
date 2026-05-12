import Defaults
import SwiftUI

struct VSCodeSettingsView: View {
    @Default(.vscodeProjectsDirectory) private var vscodeProjectsDirectory
    @Default(.vscodeScanDepth) private var scanDepth

    private var displayPath: String {
        if vscodeProjectsDirectory.isEmpty {
            return "~/Projects"
        }
        return vscodeProjectsDirectory
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(displayPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Stepper(value: $scanDepth, in: 1...10) {
                        HStack {
                            Text("扫描深度")
                            Spacer()
                            Text("\(scanDepth)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("浏览...") {
                        browseForFolder()
                    }
                    .controlSize(.small)

                    if !vscodeProjectsDirectory.isEmpty {
                        Button("重置") {
                            vscodeProjectsDirectory = ""
                            VSCodeRecentProjectsService.shared.refresh()
                        }
                        .controlSize(.small)
                    }

                    Spacer()

                    Button("刷新") {
                        VSCodeRecentProjectsService.shared.refresh()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("VS Code")
            } footer: {
                Text("Seven Island 会列出配置目录中指定扫描深度内的文件夹，并在新窗口中打开。")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("VS Code")
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 VS Code 项目目录"
        panel.directoryURL = {
            if vscodeProjectsDirectory.isEmpty {
                return VSCodeRecentProjectsService.defaultProjectsDirectoryURL()
            }
            return URL(fileURLWithPath: (vscodeProjectsDirectory as NSString).expandingTildeInPath)
        }()

        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            vscodeProjectsDirectory = url.path
            VSCodeRecentProjectsService.shared.refresh()
        }
    }
}
