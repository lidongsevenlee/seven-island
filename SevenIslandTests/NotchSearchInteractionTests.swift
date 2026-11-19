import AppKit
@testable import Seven_Island

@main
enum NotchSearchInteractionTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else {
            fputs("FAIL: interaction tests require a connected screen\n", stderr)
            exit(1)
        }
        let vm = BoringViewModel(screenUUID: screen.displayUUID)

        vm.open()
        vm.isTextInputFocused = true
        let searchPosition = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 60)
        vm.closeAfterHoverExit(position: searchPosition)
        expect(vm.notchState == .open, "keeps keyboard search expanded when cursor hiding ends hover tracking")

        let outsidePosition = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 400)
        vm.closeAfterHoverExit(position: outsidePosition)
        expect(vm.notchState == .closed, "dismisses when the mouse leaves the notch during search")
        expect(!vm.isTextInputFocused, "clears focus after a genuine hover exit")

        vm.open()
        vm.isTextInputFocused = true
        vm.closeAutomatically()
        expect(vm.notchState == .open, "keeps the notch expanded while search has keyboard focus")

        vm.closeAutomatically()
        expect(vm.notchState == .open, "keeps search expanded across repeated passive dismissal requests")

        vm.isTextInputFocused = false
        vm.closeAutomatically()
        expect(vm.notchState == .closed, "resumes automatic dismissal after search loses focus")

        vm.open()
        vm.isTextInputFocused = true
        vm.close()
        expect(vm.notchState == .closed, "allows explicit dismissal while search has focus")
        expect(!vm.isTextInputFocused, "clears search focus on explicit dismissal")

        vm.open()
        vm.closeAutomatically()
        expect(vm.notchState == .closed, "automatically dismisses an unfocused notch")

        let otherWindow = BoringViewModel()
        vm.open()
        otherWindow.open()
        vm.isTextInputFocused = true
        otherWindow.closeAutomatically()
        vm.closeAutomatically()
        expect(otherWindow.notchState == .closed, "keeps search focus local to its window")
        expect(vm.notchState == .open, "preserves search in the focused window")

        vm.isTextInputFocused = false
        vm.isPinnedOpen = true
        vm.closeAfterHoverExit(position: outsidePosition)
        expect(vm.notchState == .open, "keeps the pinned panel open after hover exit")
        vm.closeAutomatically()
        expect(vm.notchState == .open, "keeps the pinned panel open after a timed dismissal")
        vm.closeUnlessPinned()
        expect(vm.notchState == .open, "keeps the pinned panel open after a tab action")

        otherWindow.open()
        otherWindow.closeAutomatically()
        expect(otherWindow.notchState == .closed, "keeps the pin local to its panel")

        vm.isPinnedOpen = false
        vm.closeAfterHoverExit(position: outsidePosition)
        expect(vm.notchState == .closed, "resumes hover dismissal after unpinning")

        vm.open()
        vm.isPinnedOpen = true
        vm.close()
        expect(vm.notchState == .closed, "allows explicit dismissal of a pinned panel")
        expect(!vm.isPinnedOpen, "clears the pin on explicit dismissal")

        vm.destroy()
        otherWindow.destroy()
        print("NotchSearchInteractionTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
