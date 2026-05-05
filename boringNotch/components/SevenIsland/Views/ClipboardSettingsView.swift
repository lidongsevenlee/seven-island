import SwiftUI

struct ClipboardSettingsView: View {
    @AppStorage("sevenIslandClipboardHistoryEnabled") private var clipboardHistoryEnabled = true
    @AppStorage("sevenIslandClipboardHistoryLimit") private var clipboardHistoryLimit = 100

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
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Clipboard")
        .onChange(of: clipboardHistoryLimit) {
            ClipboardHistoryStore.shared.reloadConfiguration()
        }
    }
}
