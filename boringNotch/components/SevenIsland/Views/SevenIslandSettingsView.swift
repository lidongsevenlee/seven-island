import SwiftUI

struct SevenIslandSettingsView: View {
    @AppStorage("sevenIslandClipboardHistoryEnabled") private var clipboardHistoryEnabled = true
    @AppStorage("sevenIslandClipboardHistoryLimit") private var clipboardHistoryLimit = 100
    @AppStorage("sevenIslandShowMissingVSCodeProjects") private var showMissingVSCodeProjects = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable clipboard history", isOn: $clipboardHistoryEnabled)
                    .tint(.effectiveAccent)
                Stepper(value: $clipboardHistoryLimit, in: 10...100, step: 10) {
                    Text("Clipboard items: \(clipboardHistoryLimit)")
                }
                Button("Clear clipboard history") {
                    ClipboardHistoryStore.shared.clear()
                }
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Seven Island stores only text and links copied while the app is running.")
            }

            Section {
                Toggle("Show missing project folders", isOn: $showMissingVSCodeProjects)
                    .tint(.effectiveAccent)
                Button("Refresh recent projects") {
                    VSCodeRecentProjectsService.shared.refresh(includeMissing: showMissingVSCodeProjects)
                }
            } header: {
                Text("VS Code")
            }

            Section {
                Button("Open Codex") {
                    CodexStatusService.shared.openCodex()
                }
                Button("Refresh Codex status") {
                    CodexStatusService.shared.refresh()
                }
            } header: {
                Text("Codex")
            } footer: {
                Text("Quota is not read from private APIs. Open Codex to view current quota and account details.")
            }
        }
        .navigationTitle("Seven Island")
        .onChange(of: clipboardHistoryLimit) {
            ClipboardHistoryStore.shared.reloadConfiguration()
        }
    }
}
