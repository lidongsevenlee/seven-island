import Defaults
import SwiftUI

struct VSCodeSettingsView: View {
    @Default(.vscodeProjectsDirectory) private var vscodeProjectsDirectory
    @Default(.vscodePinnedFolders) private var vscodePinnedFolders
    @Default(.vscodeIncludeHidden) private var vscodeIncludeHidden
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

                Toggle("包含隐藏文件夹", isOn: $vscodeIncludeHidden)
                    .onChange(of: vscodeIncludeHidden) {
                        VSCodeRecentProjectsService.shared.refresh()
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
                Text("扫描目录")
            } footer: {
                Text("Seven Island 会列出配置目录中指定扫描深度内的文件夹，并在新窗口中打开。")
            }

            Section {
                if vscodePinnedFolders.isEmpty {
                    Text("尚无独立文件夹")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vscodePinnedFolders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(.secondary)
                            Text(folder.path)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                removePinned(folder)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help("移除此文件夹")
                        }
                    }
                }

                Button {
                    addPinnedFolder()
                } label: {
                    Label("添加独立文件夹...", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            } header: {
                Text("独立文件夹")
            } footer: {
                Text("独立文件夹不参与扫描，会直接作为项目列出。支持添加以点（.）开头的隐藏文件夹。")
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
        panel.showsHiddenFiles = vscodeIncludeHidden
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

    private func addPinnedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.message = "选择需要直接列出的独立文件夹（可多选）"

        let response = panel.runModal()
        if response == .OK, !panel.urls.isEmpty {
            var combined = vscodePinnedFolders
            for url in panel.urls where !combined.contains(url) {
                combined.append(url)
            }
            vscodePinnedFolders = combined
            VSCodeRecentProjectsService.shared.refresh()
        }
    }

    private func removePinned(_ folder: URL) {
        vscodePinnedFolders = vscodePinnedFolders.filter { $0 != folder }
        VSCodeRecentProjectsService.shared.refresh()
    }
}