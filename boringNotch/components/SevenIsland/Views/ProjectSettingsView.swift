import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSettingsView: View {
    @Default(.vscodeProjectsDirectory) private var vscodeProjectsDirectory
    @Default(.vscodePinnedFolders) private var vscodePinnedFolders
    @Default(.vscodeIncludeHidden) private var vscodeIncludeHidden
    @Default(.vscodeScanDepth) private var scanDepth
    @Default(.projectOpenMethods) private var openMethods
    @Default(.projectDefaultOpenMethodID) private var defaultMethodID
    @State private var editingMethod: ProjectOpenMethod?

    private var displayPath: String {
        if vscodeProjectsDirectory.isEmpty {
            return "~/Projects"
        }
        return vscodeProjectsDirectory
    }

    var body: some View {
        Form {
            Section("打开方式") {
                SettingsPicker("点击项目时打开", selection: Binding(
                    get: { ProjectOpenMethod.preferred(in: openMethods, id: defaultMethodID)?.id ?? "" },
                    set: { defaultMethodID = $0 }
                ), options: openMethods.map { .init($0.id, $0.title) })

                ForEach(openMethods) { method in
                    HStack {
                        Text(method.title)
                        Spacer()
                        Button {
                            editingMethod = method
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("编辑\(method.title)")
                        .help("编辑打开方式")

                        Button {
                            openMethods.removeAll { $0.id == method.id }
                            if method.id == defaultMethodID {
                                defaultMethodID = openMethods.first?.id ?? ProjectOpenMethod.vscode.id
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除\(method.title)")
                        .help("移除打开方式")
                    }
                }

                HStack {
                    Button("添加应用…", systemImage: "plus.circle.fill") { addApplication() }
                    Spacer()
                    Button("高级配置…") { editingMethod = ProjectOpenMethod() }
                }
                .buttonStyle(.borderless)
            }

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
                        ProjectLauncherService.shared.refresh()
                    }

                HStack(spacing: 8) {
                    Button("浏览...") {
                        browseForFolder()
                    }
                    .controlSize(.small)

                    if !vscodeProjectsDirectory.isEmpty {
                        Button("重置") {
                            vscodeProjectsDirectory = ""
                            ProjectLauncherService.shared.refresh()
                        }
                        .controlSize(.small)
                    }

                    Spacer()

                    Button("刷新") {
                        ProjectLauncherService.shared.refresh()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("扫描目录")
            } footer: {
                Text("Seven Island 会列出配置目录中指定扫描深度内的文件夹。")
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
        .navigationTitle("项目")
        .sheet(item: $editingMethod) { method in
            ProjectOpenMethodEditor(method: method, save: saveMethod)
        }
    }

    private func addApplication() {
        guard let app = chooseProjectApplication() else { return }
        let method = ProjectOpenMethod.forApplication(app)
        guard !openMethods.contains(where: { existing in
            existing.id == method.id || (existing.kind == .folder && existing.applicationURL == app)
        }) else { return }
        saveMethod(method)
    }

    private func saveMethod(_ method: ProjectOpenMethod) {
        if let index = openMethods.firstIndex(where: { $0.id == method.id }) {
            openMethods[index] = method
        } else {
            openMethods.append(method)
        }
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = vscodeIncludeHidden
        panel.message = "选择项目目录"
        panel.prompt = "选取"
        panel.directoryURL = {
            if vscodeProjectsDirectory.isEmpty {
                return ProjectLauncherService.defaultProjectsDirectoryURL()
            }
            return URL(fileURLWithPath: (vscodeProjectsDirectory as NSString).expandingTildeInPath)
        }()

        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            vscodeProjectsDirectory = url.path
            ProjectLauncherService.shared.refresh()
        }
    }

    private func addPinnedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.message = "选择需要直接列出的独立文件夹（可多选）"
        panel.prompt = "选取"

        let response = panel.runModal()
        if response == .OK, !panel.urls.isEmpty {
            var combined = vscodePinnedFolders
            for url in panel.urls where !combined.contains(url) {
                combined.append(url)
            }
            vscodePinnedFolders = combined
            ProjectLauncherService.shared.refresh()
        }
    }

    private func removePinned(_ folder: URL) {
        vscodePinnedFolders = vscodePinnedFolders.filter { $0 != folder }
        ProjectLauncherService.shared.refresh()
    }
}

private func chooseProjectApplication() -> URL? {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.prompt = "选择应用"
    guard panel.runModal() == .OK else { return nil }
    return panel.url?.standardizedFileURL.resolvingSymlinksInPath()
}

private struct ProjectOpenMethodEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var method: ProjectOpenMethod
    let save: (ProjectOpenMethod) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            Form {
                TextField("名称", text: $method.title)
                SettingsPicker("打开方式", selection: $method.kind, options: ProjectOpenMethod.Kind.allCases.map {
                    .init($0, $0.title)
                })
                switch method.kind {
                case .folder:
                    applicationSelection
                case .link:
                    applicationSelection
                    TextField("URL 模板", text: $method.linkTemplate, prompt: Text("codex://threads/new?path={path}"))
                    Text("用 {path} 填入项目路径，路径会自动进行 URL 编码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .command:
                    TextField("可执行文件", text: $method.executablePath, prompt: Text("/usr/local/bin/code"))
                    LabeledContent("参数") {
                        TextEditor(text: $method.argumentTemplate)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 68)
                    }
                    Text("每行填写一个参数，用 {path} 填入项目路径。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    method.title = method.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(method)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!method.isValid)
            }
        }
        .padding(16)
        .frame(width: 450, height: 330)
    }

    private var applicationSelection: some View {
        LabeledContent("应用") {
            HStack(spacing: 8) {
                if let app = ProjectLauncherService.applicationURL(for: method) {
                    Text(app.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                } else if method.hasApplication {
                    Text("找不到应用")
                        .foregroundStyle(.secondary)
                }
                Button("选择应用…") {
                    guard let app = chooseProjectApplication() else { return }
                    method.applicationURL = app
                    method.applicationBundleID = Bundle(url: app)?.bundleIdentifier
                }
                if method.kind == .link, method.hasApplication {
                    Button("使用系统默认应用") {
                        method.applicationURL = nil
                        method.applicationBundleID = nil
                    }
                }
            }
        }
    }
}
