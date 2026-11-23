import AppKit
import Defaults
@testable import Seven_Island

@main
@MainActor
enum ProjectSearchFocusTests {
    static func main() throws {
        let testDomain = "ProjectSearchFocusTests"
        UserDefaults.standard.removePersistentDomain(forName: testDomain)
        defer { UserDefaults.standard.removePersistentDomain(forName: testDomain) }

        let projects = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projects) }

        NSApplication.shared.setActivationPolicy(.accessory)
        Defaults[.vscodeProjectsDirectory] = projects.path
        Defaults[.minimumHoverDuration] = 0
        Defaults[.openNotchOnHover] = true
        let vm = BoringViewModel()
        vm.coordinator.firstLaunch = false
        vm.coordinator.currentView = .vscodeProjects

        let panel = BoringNotchSkyLightWindow(viewModel: vm)
        panel.setFrameOrigin(NSPoint(x: -2048, y: -2048))
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        defer { panel.close() }

        vm.hoverChanged(true)
        expectTyping("swift", via: "hover expansion", in: panel, model: vm)

        vm.close()
        settle()
        vm.coordinator.currentView = .toolbox
        vm.open()
        settle()
        vm.coordinator.currentView = .vscodeProjects
        expectTyping("swift-ui", via: "tab selection", in: panel, model: vm)

        vm.close()
        settle()
        vm.toggleTabFromShortcut(.vscodeProjects)
        expectTyping("swift-ui-tests", via: "keyboard shortcut", in: panel, model: vm)

        print("ProjectSearchFocusTests passed")
    }

    private static func expectTyping(_ text: String, via route: String, in panel: NSPanel, model: BoringViewModel) {
        settle()
        guard model.notchState == .open, panel.isKeyWindow, model.isTextInputFocused,
              let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor else {
            print("FAIL: project search is not ready for typing after \(route)")
            exit(1)
        }
        precondition(editor.string == model.vscodeSearchText, "Project search restores its query when reopened")
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        RunLoop.current.run(until: .now.addingTimeInterval(0.05))
        precondition(model.vscodeSearchText == text, "The keyboard editor changes the project query after \(route)")
    }

    private static func settle() {
        RunLoop.current.run(until: .now.addingTimeInterval(0.55))
    }
}
