import Foundation
import Defaults
import KeyboardShortcuts
@testable import Seven_Island

@main
@MainActor
enum NotchWindowManagerTests {
    static func main() {
        testUnplugAndReconnect()
        testDisplaysSwapPositions()
        testSinglePanelFollowsPreferredDisplay()
        testModeSwitchAndLockScreen()
        testTabShortcuts()
        testCustomTabLayout()
        print("NotchWindowManagerTests passed")
    }

    private static func testCustomTabLayout() {
        let coordinator = BoringViewCoordinator.shared
        let previousLayout = coordinator.tabLayout
        let previousTab = coordinator.currentView
        defer {
            coordinator.updateTabLayout(previousLayout)
            coordinator.currentView = previousTab
        }

        var layout = PanelTabLayout()
        layout.move(.toolbox, onto: .clipboard)
        expect(layout.orderedTabs.map(\.view) == [.music, .toolbox, .clipboard, .vscodeProjects, .memo, .todo, .appLauncher],
               "dragging upward inserts at the target and shifts intermediate tabs")
        layout.move(.toolbox, onto: .appLauncher)
        expect(layout.orderedTabs.map(\.view) == TabModel.all.map(\.view), "dragging downward reaches the final slot")
        layout.move(.appLauncher, onto: .todo)
        layout.setVisible(false, for: .music)
        expect(layout.leadingTabs.map(\.view) == [.clipboard, .vscodeProjects, .memo, .appLauncher],
               "moves a tab across the notch and hides the chosen icon")
        expect(layout.trailingTabs.map(\.view) == [.todo, .toolbox], "preserves order on the other side")

        coordinator.currentView = .music
        coordinator.updateTabLayout(layout)
        expect(coordinator.currentView == .clipboard, "hiding the selected tab selects the first visible tab")
        expect(Defaults[.panelTabLayout] == layout, "saves tab order and visibility together")

        let vm = BoringViewModel()
        vm.toggleTabFromShortcut(.music)
        expect(vm.notchState == .closed, "a hidden tab cannot open from its shortcut")
        vm.toggleTabFromShortcut(.appLauncher)
        expect(vm.notchState == .open && coordinator.currentView == .appLauncher, "a moved tab keeps its own shortcut")

        layout.setVisible(true, for: .music)
        coordinator.updateTabLayout(layout)
        vm.toggleTabFromShortcut(.music)
        expect(coordinator.currentView == .music, "showing a tab restores its shortcut")

        for tab in TabModel.all where tab.view != .memo {
            layout.setVisible(false, for: tab.view)
        }
        layout.setVisible(false, for: .memo)
        expect(layout.visibleTabs.map(\.view) == [.memo], "preserves the final visible tab")

        let saved = Data(#"{"order":["new-tab","todo","todo"],"hidden":[]}"#.utf8)
        let restored = try! JSONDecoder().decode(PanelTabLayout.self, from: saved)
        expect(restored.orderedTabs.map(\.view) == [.todo, .music, .clipboard, .vscodeProjects, .memo, .appLauncher, .toolbox],
               "loads saved order with duplicate or unfamiliar identifiers and appends missing tabs")
    }

    private static func testTabShortcuts() {
        let coordinator = BoringViewCoordinator.shared
        let previousTab = coordinator.currentView
        defer { coordinator.currentView = previousTab }

        let tabs = TabModel.all
        let expectedTabs: [NotchViews] = [.music, .clipboard, .vscodeProjects, .memo, .todo, .appLauncher, .toolbox]
        let keys: [KeyboardShortcuts.Key] = [.one, .two, .three, .four, .five, .six, .seven]
        expect(tabs.map(\.view) == expectedTabs, "every tab is listed in header order")
        expect(Set(tabs.map { $0.shortcut.rawValue }).count == expectedTabs.count, "each tab uses a separate shortcut setting")
        for (tab, key) in zip(tabs, keys) {
            let shortcut = KeyboardShortcuts.Shortcut(key, modifiers: [.command])
            expect(tab.shortcut.defaultShortcut == shortcut, "the default shortcut follows the tab position")
        }

        let fixture = Fixture()
        let laptop = display("laptop", x: 0)
        let external = display("external", x: 1440)
        let laptopPointer = CGPoint(x: 50, y: 500)
        let externalPointer = CGPoint(x: 1500, y: 500)
        fixture.reconcile([laptop, external], mode: .allDisplays)
        let laptopModel = fixture.windows[0].viewModel
        let externalModel = fixture.windows[1].viewModel

        for tab in tabs {
            fixture.manager.toggleTab(tab.view, at: externalPointer)
            expect(externalModel.notchState == .open && coordinator.currentView == tab.view,
                   "a tab shortcut opens its tab on the pointer display")
            expect(laptopModel.notchState == .closed, "the other display stays folded")
            fixture.manager.toggleTab(tab.view, at: externalPointer)
            expect(externalModel.notchState == .closed, "repeating a tab shortcut folds the panel")
        }

        fixture.manager.toggleTab(.clipboard, at: laptopPointer)
        laptopModel.isPinnedOpen = true
        fixture.manager.toggleTab(.vscodeProjects, at: laptopPointer)
        expect(laptopModel.isPinnedOpen && coordinator.currentView == .vscodeProjects,
               "a different tab shortcut switches the open panel and preserves its pin")
        fixture.manager.toggleTab(.vscodeProjects, at: laptopPointer)
        expect(laptopModel.notchState == .closed && !laptopModel.isPinnedOpen,
               "repeating the active tab shortcut folds a pinned panel")

        let single = NotchWindowManager.Mode.singleDisplay(preferred: laptop.uuid, fallback: nil)
        fixture.reconcile([laptop, external], mode: single)
        let singleModel = fixture.windows[2].viewModel
        fixture.manager.toggleTab(.memo, at: externalPointer)
        expect(singleModel.notchState == .open && coordinator.currentView == .memo,
               "a single panel receives tab shortcuts from the other display")

        fixture.reconcile([external], mode: single)
        fixture.manager.toggleTab(.music, at: externalPointer)
        expect(coordinator.currentView == .memo, "a parked panel receives no tab shortcut")
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
