import AppKit
@testable import Seven_Island

@main
@MainActor
enum TodoPanelHeightTests {
    static func main() {
        let testDomain = "TodoPanelHeightTests"
        UserDefaults.standard.removePersistentDomain(forName: testDomain)
        defer { UserDefaults.standard.removePersistentDomain(forName: testDomain) }

        NSApplication.shared.setActivationPolicy(.accessory)
        let vm = BoringViewModel()
        vm.coordinator.currentView = .todo
        vm.coordinator.firstLaunch = false

        let panel = BoringNotchSkyLightWindow(viewModel: vm)
        panel.setFrameOrigin(NSPoint(x: -2048, y: -2048))
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        defer { panel.close() }

        let store = TodoStore.shared
        store.add("待办面板高度测试")

        vm.toggleTabFromShortcut(.todo)
        settle()
        let shortHeight = vm.notchSize.height
        precondition(vm.notchState == .open && shortHeight < openNotchSize.height)

        for pause in [0.04, 0.10, 0.18, 0.42] {
            reopenTodo(vm, after: pause)
            expectHeight(shortHeight, in: vm)
            precondition(vm.isTextInputFocused, "The active Todo composer takes keyboard focus")
        }

        vm.isPinnedOpen = true
        vm.toggleTabFromShortcut(.music)
        settle()
        expectHeight(openNotchSize.height, in: vm)
        vm.toggleTabFromShortcut(.todo)
        settle()
        expectHeight(shortHeight, in: vm)

        for index in 1...16 {
            store.add("待办面板高度测试第 \(index) 项")
        }
        settle()
        let longHeight = vm.notchSize.height
        precondition(longHeight > openNotchSize.height && longHeight <= sevenIslandFeatureNotchHeight)
        reopenTodo(vm, after: 0.10)
        expectHeight(longHeight, in: vm)

        print("TodoPanelHeightTests passed")
    }

    private static func reopenTodo(_ vm: BoringViewModel, after delay: TimeInterval) {
        vm.toggleTabFromShortcut(.todo)
        precondition(vm.notchState == .closed, "The same shortcut closes Todo")
        settle(delay)
        vm.toggleTabFromShortcut(.todo)
        settle()
    }

    private static func expectHeight(_ expected: CGFloat, in vm: BoringViewModel) {
        precondition(vm.notchState == .open && abs(vm.notchSize.height - expected) < 1,
                     "Expected an open panel at \(expected) points, got \(vm.notchState) at \(vm.notchSize.height) points")
    }

    private static func settle(_ duration: TimeInterval = 0.55) {
        RunLoop.current.run(until: Date.now.addingTimeInterval(duration))
    }
}
