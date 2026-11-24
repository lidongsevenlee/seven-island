import Foundation
import OSLog

enum NotchDiagnostics {
    static let logger = Logger(subsystem: "com.local.seven-island", category: "NotchDiagnostics")
}

@MainActor
final class NotchInteraction {
    enum OpenTrigger: String {
        case click, hover, shortcut, tabShortcut
    }

    private enum ExitTrigger: String {
        case hoverEvent, positionCheck, screenshotEnd, unpin, reorderEnd, batteryPopoverEnd
    }

    struct State: Equatable {
        var notchState: NotchState = .closed
        var allowsEscapeDismissal = false
        var isHovering = false
        var isPinnedOpen = false
        var isTextInputFocused = false
        var isBatteryPopoverActive = false
        var isSamplingScreenColor = false
        var isCapturingScreenshot = false
        var isReorderingTodo = false
    }

    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never>

    let diagnosticID = String(UUID().uuidString.prefix(8))

    private let pointerIsInside: @MainActor () -> Bool?
    private let hoverOpenDelay: @MainActor () -> Duration?
    private let schedule: Schedule
    private let onStateChange: @MainActor (State) -> Void

    private var hoverTask: Task<Void, Never>?
    private var pointerExitCheck: Task<Void, Never>?
    private var shortcutTask: Task<Void, Never>?
    private var shortcutCloseDeferredForFocus = false
    private var awaitingPointerEntry = false
    private var awaitingPointerExitAfterEscape = false

    private(set) var state = State() {
        didSet {
            if state != oldValue {
                onStateChange(state)
                updatePointerExitCheck()
            }
        }
    }

    init(
        pointerIsInside: @escaping @MainActor () -> Bool?,
        hoverOpenDelay: @escaping @MainActor () -> Duration?,
        schedule: @escaping Schedule = { delay, action in
            Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                action()
            }
        },
        onStateChange: @escaping @MainActor (State) -> Void = { _ in }
    ) {
        self.pointerIsInside = pointerIsInside
        self.hoverOpenDelay = hoverOpenDelay
        self.schedule = schedule
        self.onStateChange = onStateChange
    }

    deinit {
        hoverTask?.cancel()
        pointerExitCheck?.cancel()
        shortcutTask?.cancel()
    }

    func hoverChanged(_ hovering: Bool) {
        if !hovering && state.notchState == .open {
            NotchDiagnostics.logger.notice("""
                panel=\(self.diagnosticID, privacy: .public) event=hover_exit \
                waiting_for_entry=\(self.awaitingPointerEntry) waiting_for_escape_exit=\(self.awaitingPointerExitAfterEscape) \
                screenshot=\(self.state.isCapturingScreenshot) color_picker=\(self.state.isSamplingScreenColor) \
                reordering=\(self.state.isReorderingTodo)
                """)
        }
        guard !state.isSamplingScreenColor, !state.isCapturingScreenshot, !state.isReorderingTodo else { return }
        if awaitingPointerExitAfterEscape {
            guard !hovering, pointerIsInside() != true else { return }
            awaitingPointerExitAfterEscape = false
        }
        if awaitingPointerEntry {
            guard hovering, pointerIsInside() == true else { return }
            awaitingPointerEntry = false
        }
        cancelHoverTransition()
        if hovering {
            state.isHovering = true
            guard state.notchState == .closed, let delay = hoverOpenDelay() else { return }
            hoverTask = schedule(delay) { [weak self] in
                guard let self else { return }
                self.hoverTask = nil
                guard self.state.isHovering, self.hoverOpenDelay() != nil else { return }
                self.open(trigger: .hover)
            }
        } else {
            schedulePointerExit(trigger: .hoverEvent)
        }
    }

    func panelMoved() {
        resetPointerTracking()
    }

    func setScreenColorSampling(_ sampling: Bool) {
        guard state.notchState == .open, state.isSamplingScreenColor != sampling else { return }
        if sampling {
            cancelPendingTransitions()
        }
        state.isSamplingScreenColor = sampling
        if !sampling {
            resetPointerTracking()
        }
    }

    func setScreenshotCaptureActive(_ active: Bool) {
        guard state.notchState == .open, state.isCapturingScreenshot != active else { return }
        if active {
            cancelPendingTransitions()
            state.isCapturingScreenshot = true
        } else {
            state.isCapturingScreenshot = false
            resetPointerTracking()
            confirmPointerExit(trigger: .screenshotEnd)
            if state.notchState == .open { state.allowsEscapeDismissal = true }
        }
    }

    func setTodoReordering(_ active: Bool) {
        guard state.notchState == .open, state.isReorderingTodo != active else { return }
        state.isReorderingTodo = active
        if active {
            cancelHoverTransition()
        } else {
            resetPointerTracking()
            if !state.isHovering { schedulePointerExit(trigger: .reorderEnd) }
        }
    }

    private func resetPointerTracking() {
        cancelHoverTransition()
        let inside = pointerIsInside() == true
        if !inside { awaitingPointerExitAfterEscape = false }
        awaitingPointerEntry = state.notchState == .open && !inside
        state.isHovering = inside
    }

    func open(trigger: OpenTrigger = .click) {
        guard state.notchState == .closed else { return }
        cancelPendingTransitions()
        setOpenState(trigger: trigger)
    }

    func toggleFromShortcut() {
        if state.notchState == .open {
            NotchDiagnostics.logger.notice("panel=\(self.diagnosticID, privacy: .public) event=shortcut_close")
            close()
            return
        }

        open(trigger: .shortcut)
        shortcutTask = schedule(.seconds(3)) { [weak self] in
            guard let self else { return }
            self.shortcutTask = nil
            self.evaluateShortcutDismissal()
        }
    }

    func openFromTabShortcut() {
        cancelPendingTransitions()
        setOpenState(trigger: .tabShortcut)
        resetPointerTracking()
    }

    private func setOpenState(trigger: OpenTrigger) {
        NotchDiagnostics.logger.notice("panel=\(self.diagnosticID, privacy: .public) event=open_request trigger=\(trigger.rawValue, privacy: .public)")
        awaitingPointerExitAfterEscape = false
        var next = state
        next.notchState = .open
        next.allowsEscapeDismissal = trigger == .shortcut || trigger == .tabShortcut
        state = next
    }

    @discardableResult
    func dismissFromEscape() -> Bool {
        guard state.allowsEscapeDismissal, !state.isSamplingScreenColor, !state.isBatteryPopoverActive,
              !state.isCapturingScreenshot else { return false }
        NotchDiagnostics.logger.notice("panel=\(self.diagnosticID, privacy: .public) event=escape_close")
        close()
        awaitingPointerExitAfterEscape = pointerIsInside() == true
        return true
    }

    func setPinnedOpen(_ pinned: Bool) {
        guard state.notchState == .open, state.isPinnedOpen != pinned else { return }
        state.isPinnedOpen = pinned
        if pinned {
            shortcutCloseDeferredForFocus = false
        } else {
            confirmPointerExit(trigger: .unpin)
        }
    }

    func setTextInputFocused(_ focused: Bool) {
        guard state.notchState == .open, state.isTextInputFocused != focused else { return }
        state.isTextInputFocused = focused
        if !focused && shortcutCloseDeferredForFocus {
            shortcutCloseDeferredForFocus = false
            evaluateShortcutDismissal()
        }
    }

    func setBatteryPopoverActive(_ active: Bool) {
        guard state.isBatteryPopoverActive != active else { return }
        state.isBatteryPopoverActive = active
        if !active && !state.isHovering && state.notchState == .open {
            schedulePointerExit(trigger: .batteryPopoverEnd, respectingTextFocus: true)
        }
    }

    func closeUnlessPinned() {
        guard !state.isPinnedOpen else { return }
        close()
    }

    func close() {
        cancelPendingTransitions()
        awaitingPointerEntry = false
        awaitingPointerExitAfterEscape = false
        state = State()
    }

    func cancelPendingTransitions() {
        cancelHoverTransition()
        cancelPointerExitCheck()
        shortcutTask?.cancel()
        shortcutTask = nil
        shortcutCloseDeferredForFocus = false
    }

    private func cancelHoverTransition() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    private var pointerDismissalSuspended: Bool {
        state.isPinnedOpen || state.isBatteryPopoverActive || state.isSamplingScreenColor
            || state.isCapturingScreenshot || state.isReorderingTodo
    }

    private func cancelPointerExitCheck() {
        pointerExitCheck?.cancel()
        pointerExitCheck = nil
    }

    private func updatePointerExitCheck() {
        guard state.notchState == .open, state.isHovering, !pointerDismissalSuspended else {
            cancelPointerExitCheck()
            return
        }
        guard pointerExitCheck == nil else { return }

        // AppKit's pointer position remains available when SwiftUI misses a hover notification.
        pointerExitCheck = schedule(.milliseconds(150)) { [weak self] in
            guard let self else { return }
            self.pointerExitCheck = nil
            guard let inside = self.pointerIsInside() else {
                NotchDiagnostics.logger.notice("panel=\(self.diagnosticID, privacy: .public) event=pointer_check result=unavailable")
                return
            }
            if !inside && self.hoverTask == nil {
                self.schedulePointerExit(trigger: .positionCheck)
            }
            self.updatePointerExitCheck()
        }
    }

    private func schedulePointerExit(trigger: ExitTrigger, respectingTextFocus: Bool = false) {
        cancelHoverTransition()
        hoverTask = schedule(.milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.hoverTask = nil
            self.confirmPointerExit(trigger: trigger, respectingTextFocus: respectingTextFocus)
        }
    }

    private func confirmPointerExit(trigger: ExitTrigger, respectingTextFocus: Bool = false) {
        // Typing can cause SwiftUI to report a hover exit while the pointer is still inside.
        let pointer = pointerIsInside()
        let inside = pointer == true
        let mayClose = !inside && state.notchState == .open && !pointerDismissalSuspended
            && (!respectingTextFocus || !state.isTextInputFocused)
        if state.notchState == .open {
            let location = pointer.map { $0 ? "inside" : "outside" } ?? "unavailable"
            let action = mayClose ? "close" : "keep_open"
            NotchDiagnostics.logger.notice("""
                panel=\(self.diagnosticID, privacy: .public) event=pointer_exit_check \
                trigger=\(trigger.rawValue, privacy: .public) pointer=\(location, privacy: .public) action=\(action, privacy: .public) \
                pinned=\(self.state.isPinnedOpen) text_focus=\(self.state.isTextInputFocused) \
                respect_text_focus=\(respectingTextFocus) battery_popover=\(self.state.isBatteryPopoverActive) \
                screenshot=\(self.state.isCapturingScreenshot) color_picker=\(self.state.isSamplingScreenColor) \
                reordering=\(self.state.isReorderingTodo)
                """)
        }
        if mayClose {
            close()
        } else {
            state.isHovering = inside
        }
    }

    private func evaluateShortcutDismissal() {
        guard state.notchState == .open, !state.isPinnedOpen, !state.isReorderingTodo else { return }
        if state.isTextInputFocused {
            shortcutCloseDeferredForFocus = true
        } else if pointerIsInside() != true {
            NotchDiagnostics.logger.notice("panel=\(self.diagnosticID, privacy: .public) event=shortcut_timeout_close")
            close()
        }
    }
}
