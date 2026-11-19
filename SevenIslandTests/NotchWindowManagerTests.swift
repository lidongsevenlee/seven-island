import Foundation
@testable import Seven_Island

@main
@MainActor
enum NotchWindowManagerTests {
    static func main() {
        testUnplugAndReconnect()
        testDisplaysSwapPositions()
        testSinglePanelFollowsPreferredDisplay()
        testModeSwitchAndLockScreen()
        print("NotchWindowManagerTests passed")
    }

    private static func testUnplugAndReconnect() {
        let fixture = Fixture()
        let laptop = display("laptop", x: 0, hasNotch: true)
        let left = display("left", x: -1440)
        let right = display("right", x: 1440)
        fixture.reconcile([laptop, left, right], mode: .allDisplays)
        let laptopWindow = fixture.windows[0]
        let leftWindow = fixture.windows[1]
        let rightWindow = fixture.windows[2]

        fixture.manager.togglePanel(at: CGPoint(x: 50, y: 500))
        laptopWindow.viewModel.isPinnedOpen = true
        laptopWindow.viewModel.clipboardSearchText = "clipboard query"
        leftWindow.viewModel.open()
        leftWindow.viewModel.vscodeSearchText = "temporary query"
        rightWindow.viewModel.open()
        rightWindow.viewModel.isTextInputFocused = true
        rightWindow.viewModel.vscodeSearchText = "project query"

        let movedLaptop = display("laptop", x: -1440, hasNotch: true)
        fixture.reconcile([movedLaptop, right], mode: .allDisplays)
        expect(fixture.windows.count == 3, "plugging out a display reuses the surviving windows")
        expect(leftWindow.disposeCount == 1, "the removed display window is disposed once")
        expect(laptopWindow.lastAnchor == movedLaptop.notchAnchor, "a surviving window follows its display")
        expect(laptopWindow.viewModel.isPinnedOpen, "the moved window keeps its pin")
        expect(laptopWindow.viewModel.notchState == .open, "the moved window keeps its expansion")
        expect(laptopWindow.viewModel.clipboardSearchText == "clipboard query", "the moved window keeps its search text")
        expect(rightWindow.viewModel.isTextInputFocused, "the other surviving window keeps input focus")
        expect(rightWindow.viewModel.vscodeSearchText == "project query", "the other surviving window keeps its search text")

        fixture.reconcile([laptop, left, right], mode: .allDisplays)
        expect(fixture.windows.count == 4, "reconnecting creates a fresh window for that display")
        let reconnected = fixture.windows[3]
        expect(reconnected.viewModel !== leftWindow.viewModel, "the reconnected display gets a fresh model")
        expect(reconnected.viewModel.notchState == .closed, "the reconnected panel starts collapsed")
        expect(reconnected.viewModel.vscodeSearchText.isEmpty, "the reconnected panel starts with an empty search")
        expect(reconnected.lastAnchor == left.notchAnchor, "the reconnected window uses the current coordinates")
        expect(laptopWindow.disposeCount == 0 && rightWindow.disposeCount == 0, "surviving windows stay mounted")
    }

    private static func testDisplaysSwapPositions() {
        let fixture = Fixture()
        let laptop = display("laptop", x: 0, hasNotch: true)
        let external = display("external", x: -1440, y: 900)
        fixture.reconcile([laptop, external], mode: .allDisplays)
        fixture.reconcile(
            [display("laptop", x: -1440, y: 900, hasNotch: true), display("external", x: 0)],
            mode: .allDisplays
        )
        expect(fixture.windows.count == 2, "swapping coordinates preserves both window instances")
        expect(fixture.windows[0].lastAnchor == CGPoint(x: -720, y: 1800), "the laptop window follows its UUID")
        expect(fixture.windows[1].lastAnchor == CGPoint(x: 720, y: 900), "the external window follows its UUID")
        expect(fixture.windows[0].viewModel.display?.hasPhysicalNotch == true, "the laptop keeps its hardware notch geometry")
        expect(fixture.windows[1].viewModel.display?.hasPhysicalNotch == false, "the external panel uses external display geometry")
    }

    private static func testSinglePanelFollowsPreferredDisplay() {
        let fixture = Fixture()
        let laptop = display("laptop", x: 0, hasNotch: true)
        let external = display("external", x: 1440)
        let preferExternal = NotchWindowManager.Mode.singleDisplay(preferred: external.uuid, fallback: laptop.uuid)

        fixture.reconcile([], mode: preferExternal)
        expect(fixture.windows.isEmpty, "headless startup defers window creation")
        fixture.reconcile([laptop, external], mode: .singleDisplay(preferred: laptop.uuid, fallback: external.uuid))
        let window = fixture.windows[0]
        let model = window.viewModel
        model.open()
        model.setOpenNotchHeight(310)
        model.isPinnedOpen = true
        model.clipboardSearchText = "remember this"
        model.vscodeSearchText = "workspace"

        fixture.reconcile([laptop, external], mode: preferExternal)
        expect(window.lastAnchor == external.notchAnchor, "manually selecting a display moves the window")
        expect(model.closedNotchSize == external.closedNotchSize, "the external display supplies its own closed size")
        expect(model.notchSize.height == 310, "the move preserves expanded height")

        fixture.reconcile([laptop], mode: preferExternal)
        expect(window.lastAnchor == laptop.notchAnchor, "a disconnected preferred display falls back immediately")
        expect(model.closedNotchSize == laptop.closedNotchSize, "the fallback refreshes the closed size")

        fixture.reconcile([laptop], mode: .singleDisplay(preferred: external.uuid, fallback: nil))
        expect(window.hideCount == 1 && window.disposeCount == 0, "disabling automatic switching parks the same window")
        fixture.manager.togglePanel(at: CGPoint(x: 50, y: 500))
        expect(model.notchState == .open, "a parked window receives no shortcut")

        fixture.reconcile([laptop], mode: preferExternal)
        expect(window.isShowing && window.lastAnchor == laptop.notchAnchor, "re-enabling fallback restores the same window")
        fixture.reconcile([laptop, external], mode: preferExternal)
        expect(window.lastAnchor == external.notchAnchor, "the window returns to the reconnected preferred display")
        expect(fixture.windows.count == 1 && window.disposeCount == 0, "all single-display changes preserve the original window")
        expect(model.notchState == .open && model.notchSize.height == 310, "the original expansion survives fallback and return")
        expect(model.isPinnedOpen, "the original pin survives fallback and return")
        expect(model.clipboardSearchText == "remember this" && model.vscodeSearchText == "workspace", "the original search text survives")

        model.close()
        expect(model.notchSize == external.closedNotchSize, "closing uses the new display's geometry")
    }

    private static func testModeSwitchAndLockScreen() {
        let fixture = Fixture()
        let laptop = display("laptop", x: 0, hasNotch: true)
        let external = display("external", x: 1440)
        let single = NotchWindowManager.Mode.singleDisplay(preferred: laptop.uuid, fallback: nil)
        fixture.reconcile([laptop, external], mode: single)
        let singleWindow = fixture.windows[0]
        fixture.reconcile([laptop, external], mode: .allDisplays)
        expect(singleWindow.disposeCount == 1, "switching mode removes the inactive single window")

        fixture.reconcile([laptop, external], mode: .allDisplays, presentation: .lockScreen)
        expect(fixture.windows.count == 3 && fixture.windows[2].onLockScreen, "lock-screen presentation reuses active windows")
        fixture.reconcile([laptop], mode: .allDisplays, presentation: .hidden)
        expect(fixture.windows[1].disposeCount == 1 && fixture.windows[2].disposeCount == 1, "hidden presentation releases the active windows")
        fixture.reconcile([laptop, external], mode: .allDisplays, presentation: .hidden)
        expect(fixture.windows.count == 3, "display changes during hidden presentation keep windows absent")
        fixture.reconcile([laptop, external], mode: single)
        expect(fixture.windows.count == 4 && fixture.windows[3].viewModel === singleWindow.viewModel, "single mode restores its original model")
        expect(!fixture.windows[3].onLockScreen, "unlock restores desktop presentation")
    }

    private static func display(_ uuid: String, x: CGFloat, y: CGFloat = 0, hasNotch: Bool = false) -> NotchDisplay {
        NotchDisplay(
            uuid: uuid,
            frame: CGRect(x: x, y: y, width: 1440, height: 900),
            closedNotchSize: hasNotch ? CGSize(width: 210, height: 38) : CGSize(width: 185, height: 24),
            menuBarHeight: hasNotch ? 38 : 24,
            hasPhysicalNotch: hasNotch
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private final class Fixture {
        private(set) var windows: [FakeWindow] = []

        lazy var manager = NotchWindowManager { [unowned self] model in
            let window = FakeWindow(viewModel: model)
            windows.append(window)
            return window
        }

        func reconcile(
            _ displays: [NotchDisplay],
            mode: NotchWindowManager.Mode,
            presentation: NotchWindowManager.Presentation = .desktop
        ) {
            manager.reconcile(displays: displays, mode: mode, presentation: presentation)
        }
    }

    @MainActor
    private final class FakeWindow: NotchPanelWindow {
        let viewModel: BoringViewModel
        private(set) var lastAnchor: CGPoint?
        private(set) var onLockScreen = false
        private(set) var isShowing = false
        private(set) var hideCount = 0
        private(set) var disposeCount = 0

        init(viewModel: BoringViewModel) {
            self.viewModel = viewModel
        }

        func show(at notchAnchor: CGPoint, onLockScreen: Bool) {
            lastAnchor = notchAnchor
            self.onLockScreen = onLockScreen
            isShowing = true
        }

        func hide() {
            hideCount += 1
            isShowing = false
        }

        func dispose() {
            disposeCount += 1
            isShowing = false
        }
    }
}
