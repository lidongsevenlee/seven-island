import Defaults
import SwiftUI

struct VSCodeSettingsView: View {
    @Default(.vscodeProjectsDirectory) private var vscodeProjectsDirectory

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
                    Button("Browse...") {
                        browseForFolder()
                    }
                    .controlSize(.small)

                    if !vscodeProjectsDirectory.isEmpty {
                        Button("Reset") {
                            vscodeProjectsDirectory = ""
                            VSCodeRecentProjectsService.shared.refresh()
                        }
                        .controlSize(.small)
                    }

                    Spacer()

                    Button("Refresh") {
                        VSCodeRecentProjectsService.shared.refresh()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("VS Code")
            } footer: {
                Text("Seven Island lists first-level folders from the configured directory and opens them in a new VS Code window.")
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
        panel.message = "Choose a directory of VS Code projects"
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
