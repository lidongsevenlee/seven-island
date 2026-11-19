@MainActor
final class NotchInteraction {
    struct State: Equatable {
        var notchState: NotchState = .closed
        var isHovering = false
        var isPinnedOpen = false
        var isTextInputFocused = false
        var isBatteryPopoverActive = false
        var isSamplingScreenColor = false
    }

    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never>

    private let pointerIsInside: @MainActor () -> Bool
    private let hoverOpenDelay: @MainActor () -> Duration?
    private let schedule: Schedule
    private let onStateChange: @MainActor (State) -> Void

    private var hoverTask: Task<Void, Never>?
    private var shortcutTask: Task<Void, Never>?
    private var shortcutCloseDeferredForFocus = false
    private var awaitingPointerEntry = false

    private(set) var state = State() {
        didSet {
            if state != oldValue {
                onStateChange(state)
            }
        }
    }

    init(
        pointerIsInside: @escaping @MainActor () -> Bool,
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
        shortcutTask?.cancel()
    }

    func hoverChanged(_ hovering: Bool) {
        guard !state.isSamplingScreenColor else { return }
        if awaitingPointerEntry {
            guard hovering, pointerIsInside() else { return }
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
                self.open()
            }
        } else {
            schedulePointerExit()
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

    private func resetPointerTracking() {
        cancelHoverTransition()
        let inside = pointerIsInside()
        awaitingPointerEntry = state.notchState == .open && !inside
        state.isHovering = inside
    }

    func open() {
        guard state.notchState == .closed else { return }
        cancelPendingTransitions()
        state.notchState = .open
    }

    func toggleFromShortcut() {
        if state.notchState == .open {
            close()
            return
        }

        open()
        shortcutTask = schedule(.seconds(3)) { [weak self] in
            guard let self else { return }
            self.shortcutTask = nil
            self.evaluateShortcutDismissal()
        }
    }

    func setPinnedOpen(_ pinned: Bool) {
        guard state.notchState == .open, state.isPinnedOpen != pinned else { return }
        state.isPinnedOpen = pinned
        if pinned {
            shortcutCloseDeferredForFocus = false
        } else {
            confirmPointerExit()
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
            schedulePointerExit(respectingTextFocus: true)
        }
    }

    func closeUnlessPinned() {
        guard !state.isPinnedOpen else { return }
        close()
    }

    func close() {
        cancelPendingTransitions()
        awaitingPointerEntry = false
        state = State()
    }

    func cancelPendingTransitions() {
        cancelHoverTransition()
        shortcutTask?.cancel()
        shortcutTask = nil
        shortcutCloseDeferredForFocus = false
    }

    private func cancelHoverTransition() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    private func schedulePointerExit(respectingTextFocus: Bool = false) {
        cancelHoverTransition()
        hoverTask = schedule(.milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.hoverTask = nil
            self.confirmPointerExit(respectingTextFocus: respectingTextFocus)
        }
    }

    private func confirmPointerExit(respectingTextFocus: Bool = false) {
        // Typing can cause SwiftUI to report a hover exit while the pointer is still inside.
        let inside = pointerIsInside()
        if !inside && state.notchState == .open && !state.isPinnedOpen && !state.isBatteryPopoverActive
            && !state.isSamplingScreenColor
            && (!respectingTextFocus || !state.isTextInputFocused) {
            close()
        } else {
            state.isHovering = inside
        }
    }

    private func evaluateShortcutDismissal() {
        guard state.notchState == .open, !state.isPinnedOpen else { return }
        if state.isTextInputFocused {
            shortcutCloseDeferredForFocus = true
        } else if !pointerIsInside() {
            close()
        }
    }
}
