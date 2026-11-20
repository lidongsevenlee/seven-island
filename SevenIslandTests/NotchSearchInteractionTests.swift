import AppKit
@testable import Seven_Island

@main
@MainActor
enum NotchSearchInteractionTests {
    static func main() {
        testHoverOpensAfterDwell()
        testHoverExitUsesPointerLocation()
        testWindowMovePreservesExpansion()
        testScreenColorSamplingPreservesExpansion()
        testScreenColorFormats()
        testShortcutTimeoutUsesPointerLocation()
        testShortcutTimeoutWaitsForBlur()
        testTabShortcutWhilePointerIsOutside()
        testPinControlsDismissal()
        testReopeningCancelsOldTimeout()
        testPanelsHaveIndependentTimers()
        testBatteryPopoverDismissal()
        print("NotchSearchInteractionTests passed")
    }

    private static func testTabShortcutWhilePointerIsOutside() {
        let panel = Panel()
        panel.interaction.toggleFromShortcut()
        panel.clock.advance(.seconds(1))

        panel.interaction.openFromTabShortcut()
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.seconds(4))
        expect(!panel.isClosed, "a tab shortcut replaces a prior transient opening and waits for pointer entry")

        panel.pointerInside = true
        panel.interaction.hoverChanged(true)
        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(panel.isClosed, "hover dismissal works after the pointer has entered the tab")
    }

    private static func testHoverOpensAfterDwell() {
        let panel = Panel()
        panel.pointerInside = true
        panel.interaction.hoverChanged(true)
        panel.clock.advance(.milliseconds(299))
        expect(panel.isClosed, "hover waits for the configured dwell")

        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(101))
        expect(panel.isClosed, "leaving cancels a pending hover open")

        panel.pointerInside = true
        panel.interaction.hoverChanged(true)
        panel.clock.advance(.milliseconds(300))
        expect(!panel.isClosed, "hover opens after the configured dwell")

        panel.interaction.close()
        panel.hoverDelay = nil
        panel.interaction.hoverChanged(true)
        panel.clock.advance(.seconds(1))
        expect(panel.isClosed, "hover respects the disabled setting")

        panel.interaction.open()
        panel.clock.advance(.seconds(3))
        expect(!panel.isClosed, "click opens without starting the shortcut timer")
    }

    private static func testHoverExitUsesPointerLocation() {
        let panel = Panel()
        panel.interaction.open()
        panel.pointerInside = true
        panel.interaction.setTextInputFocused(true)
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(!panel.isClosed, "cursor hiding during typing keeps the panel open")

        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(99))
        expect(!panel.isClosed, "hover exit observes the grace period")
        panel.pointerInside = true
        panel.interaction.hoverChanged(true)
        panel.clock.advance(.milliseconds(1))
        expect(!panel.isClosed, "re-entering cancels a pending hover exit")

        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(panel.isClosed, "genuine mouse exit closes the panel during input")
        expect(!panel.interaction.state.isTextInputFocused, "closing clears input focus")
    }

    private static func testShortcutTimeoutUsesPointerLocation() {
        let panel = Panel()
        panel.interaction.toggleFromShortcut()
        panel.clock.advance(.milliseconds(2999))
        expect(!panel.isClosed, "shortcut opens immediately and waits three seconds")
        panel.clock.advance(.milliseconds(1))
        expect(panel.isClosed, "shortcut timeout dismisses when the pointer is outside")

        panel.interaction.toggleFromShortcut()
        panel.pointerInside = true
        panel.clock.advance(.seconds(3))
        expect(!panel.isClosed, "shortcut timeout keeps the hovered panel open")

        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(panel.isClosed, "hover exit still dismisses after the shortcut timeout")
    }

    private static func testWindowMovePreservesExpansion() {
        let panel = Panel()
        panel.interaction.open()
        panel.interaction.hoverChanged(false)
        panel.interaction.panelMoved()
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(!panel.isClosed, "movement preserves expansion across pending and new hover exits")

        panel.pointerInside = true
        panel.interaction.hoverChanged(true)
        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(panel.isClosed, "hover dismissal resumes after entering the moved panel")
    }

    private static func testScreenColorSamplingPreservesExpansion() {
        let panel = Panel()
        panel.interaction.toggleFromShortcut()
        panel.interaction.setScreenColorSampling(true)
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.seconds(3))
        expect(!panel.isClosed, "sampling keeps the panel open past pointer exit and shortcut timeout")

        panel.interaction.setScreenColorSampling(false)
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(!panel.isClosed, "sampling leaves the result visible outside the panel")

        panel.pointerInside = true
        panel.interaction.hoverChanged(true)
        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(panel.isClosed, "hover dismissal resumes after entering the panel")
    }

    private static func testScreenColorFormats() {
        let color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        let sample = ScreenColorSample(color)
        expect(sample?.hex == "#FF8000", "formats a sampled color as six-digit sRGB HEX")
        expect(sample?.rgb == "rgb(255, 128, 0)", "formats a sampled color as sRGB byte values")
    }

    private static func testShortcutTimeoutWaitsForBlur() {
        let panel = Panel()
        panel.interaction.setTextInputFocused(true)
        expect(panel.isClosed, "a closed panel stays closed on input focus")

        panel.interaction.toggleFromShortcut()
        panel.interaction.setTextInputFocused(true)
        panel.clock.advance(.seconds(3))
        expect(!panel.isClosed, "focused input defers shortcut dismissal")
        panel.interaction.setTextInputFocused(false)
        expect(panel.isClosed, "blur retries the expired shortcut dismissal outside the panel")

        panel.interaction.toggleFromShortcut()
        panel.interaction.setTextInputFocused(true)
        panel.clock.advance(.seconds(3))
        panel.pointerInside = true
        panel.interaction.setTextInputFocused(false)
        expect(!panel.isClosed, "blur keeps the panel open when the pointer is inside")
        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(panel.isClosed, "hover exit dismisses after blur inside the panel")

        panel.interaction.toggleFromShortcut()
        panel.interaction.setTextInputFocused(true)
        panel.interaction.setTextInputFocused(false)
        expect(!panel.isClosed, "blur before timeout leaves the original deadline in place")
        panel.clock.advance(.seconds(3))
        expect(panel.isClosed, "the original timeout still dismisses after early blur")
    }

    private static func testPinControlsDismissal() {
        let panel = Panel()
        panel.interaction.toggleFromShortcut()
        panel.interaction.setPinnedOpen(true)
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.seconds(3))
        expect(!panel.isClosed, "pin keeps the panel open through hover exit and shortcut timeout")
        panel.interaction.closeUnlessPinned()
        expect(!panel.isClosed, "pin keeps the panel open after a clipboard or project action")

        panel.pointerInside = true
        panel.interaction.setPinnedOpen(false)
        expect(!panel.isClosed, "unpin keeps the panel open while the pointer is inside")
        panel.interaction.setPinnedOpen(true)
        panel.pointerInside = false
        panel.interaction.setPinnedOpen(false)
        expect(panel.isClosed, "unpin dismisses with the pointer outside")

        panel.interaction.toggleFromShortcut()
        panel.interaction.setTextInputFocused(true)
        panel.interaction.setPinnedOpen(true)
        panel.interaction.toggleFromShortcut()
        expect(panel.isClosed, "explicit shortcut dismissal works with focus and pin")
        expect(!panel.interaction.state.isPinnedOpen, "explicit dismissal clears the pin")
        expect(!panel.interaction.state.isTextInputFocused, "explicit dismissal clears focus")
    }

    private static func testReopeningCancelsOldTimeout() {
        let panel = Panel()
        panel.interaction.toggleFromShortcut()
        panel.interaction.closeUnlessPinned()
        expect(panel.isClosed, "a clipboard or project action dismisses the unpinned panel")
        panel.pointerInside = true
        panel.interaction.hoverChanged(true)
        panel.clock.advance(.milliseconds(300))
        expect(!panel.isClosed, "hover reopens after early dismissal")

        panel.pointerInside = false
        panel.clock.advance(.seconds(3))
        expect(!panel.isClosed, "the later opening survives the old shortcut deadline")
    }

    private static func testPanelsHaveIndependentTimers() {
        let clock = Clock()
        let first = Panel(clock: clock)
        let second = Panel(clock: clock)
        first.interaction.toggleFromShortcut()
        clock.advance(.seconds(1))
        second.interaction.toggleFromShortcut()
        clock.advance(.seconds(2))
        expect(first.isClosed, "opening the second panel preserves the first deadline")
        expect(!second.isClosed, "the second panel stays open until its own deadline")
        clock.advance(.seconds(1))
        expect(second.isClosed, "the second panel dismisses at its own deadline")

        first.interaction.toggleFromShortcut()
        second.interaction.toggleFromShortcut()
        first.interaction.setTextInputFocused(true)
        clock.advance(.seconds(3))
        expect(!first.isClosed, "focused panel remains open at its deadline")
        expect(second.isClosed, "focus applies to its own panel only")
    }

    private static func testBatteryPopoverDismissal() {
        let panel = Panel()
        panel.interaction.open()
        panel.interaction.setBatteryPopoverActive(true)
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(!panel.isClosed, "battery popover holds the panel open after pointer exit")

        panel.interaction.setBatteryPopoverActive(false)
        panel.pointerInside = true
        panel.clock.advance(.milliseconds(100))
        expect(!panel.isClosed, "popover dismissal rechecks the actual pointer")
        panel.pointerInside = false
        panel.interaction.hoverChanged(false)
        panel.clock.advance(.milliseconds(100))
        expect(panel.isClosed, "hover exit resumes after the popover closes")

        panel.interaction.open()
        panel.interaction.setBatteryPopoverActive(true)
        panel.interaction.setBatteryPopoverActive(false)
        panel.clock.advance(.milliseconds(100))
        expect(panel.isClosed, "popover dismissal closes with the pointer outside")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private final class Panel {
        let clock: Clock
        var pointerInside = false
        var hoverDelay: Duration? = .milliseconds(300)

        lazy var interaction = NotchInteraction(
            pointerIsInside: { [unowned self] in pointerInside },
            hoverOpenDelay: { [unowned self] in hoverDelay },
            schedule: clock.schedule
        )

        var isClosed: Bool { interaction.state.notchState == .closed }

        init(clock: Clock? = nil) {
            self.clock = clock ?? Clock()
        }
    }

    @MainActor
    private final class Clock {
        private struct Entry {
            let deadline: Duration
            let task: Task<Void, Never>
            let action: @MainActor () -> Void
        }

        private var now = Duration.zero
        private var entries: [Entry] = []

        func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
            let task = Task<Void, Never> {}
            entries.append(Entry(deadline: now + delay, task: task, action: action))
            return task
        }

        func advance(_ duration: Duration) {
            let target = now + duration
            while let next = entries.indices.min(by: { entries[$0].deadline < entries[$1].deadline }),
                  entries[next].deadline <= target {
                let entry = entries.remove(at: next)
                now = entry.deadline
                if !entry.task.isCancelled {
                    entry.action()
                }
            }
            now = target
        }
    }
}
