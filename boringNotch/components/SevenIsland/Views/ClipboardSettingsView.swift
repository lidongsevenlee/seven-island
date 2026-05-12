import SwiftUI

struct ClipboardSettingsView: View {
    @AppStorage("sevenIslandClipboardHistoryEnabled") private var clipboardHistoryEnabled = true
    @AppStorage("sevenIslandClipboardHistoryLimit") private var clipboardHistoryLimit = 100

    var body: some View {
        Form {
            Section {
                Toggle("启用剪贴板历史", isOn: $clipboardHistoryEnabled)
                    .tint(.effectiveAccent)
                Stepper(value: $clipboardHistoryLimit, in: 10...100, step: 10) {
                    Text("剪贴板项目数：\(clipboardHistoryLimit)")
                }
                Button("清除剪贴板历史") {
                    ClipboardHistoryStore.shared.clear()
                }
            } header: {
                Text("剪贴板")
            } footer: {
                Text("Seven Island 仅存储应用运行时复制的文本和链接。")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("剪贴板")
        .onChange(of: clipboardHistoryLimit) {
            ClipboardHistoryStore.shared.reloadConfiguration()
        }
    }
}
