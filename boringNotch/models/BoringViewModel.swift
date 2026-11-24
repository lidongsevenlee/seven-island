//
//  BoringViewModel.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Combine
import Defaults
import OSLog
import SwiftUI

@MainActor
class BoringViewModel: NSObject, ObservableObject {
    // Plain references — `@ObservedObject` only triggers SwiftUI invalidation
    // inside a `View` and silently does nothing on an NSObject. These are kept
    // as bare `let`s so the intent is clear.
    let coordinator = BoringViewCoordinator.shared
    let detector = FullscreenMediaDetector.shared

    let animationLibrary: BoringAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private var interactionState = NotchInteraction.State()

    var notchState: NotchState { interactionState.notchState }
    var isHovering: Bool { interactionState.isHovering }

    var isPinnedOpen: Bool {
        get { interactionState.isPinnedOpen }
        set { interaction.setPinnedOpen(newValue) }
    }

    var isBatteryPopoverActive: Bool {
        get { interactionState.isBatteryPopoverActive }
        set { interaction.setBatteryPopoverActive(newValue) }
    }

    var isTextInputFocused: Bool {
        get { interactionState.isTextInputFocused }
        set { interaction.setTextInputFocused(newValue) }
    }

    weak var panelWindow: NSWindow?
    private var didMakePanelKeyForKeyboardInput = false

    func makePanelKeyForKeyboardInput() {
        guard notchState == .open, !interactionState.isCapturingScreenshot,
              let panelWindow, panelWindow.isVisible else { return }
        if !panelWindow.isKeyWindow { panelWindow.makeKey() }
        didMakePanelKeyForKeyboardInput = panelWindow.isKeyWindow
    }

    private lazy var interaction = NotchInteraction(
        pointerIsInside: { [weak self] in
            guard let self, self.display != nil else { return nil }
            return self.isMouseHovering()
        },
        hoverOpenDelay: { [weak self] in
            guard let self, !self.coordinator.firstLaunch, !self.coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return nil }
            return .seconds(Defaults[.minimumHoverDuration])
        },
        onStateChange: { [weak self] state in self?.applyInteractionState(state) }
    )

    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = true

    @Published var edgeAutoOpenActive: Bool = false
    @Published var isHoveringCalendar: Bool = false
    @Published var clipboardSearchText: String = ""
    @Published var clipboardFilter: ClipboardHistoryItem.Kind?
    @Published var vscodeSearchText: String = ""
    @Published var appLauncherSearchText: String = ""
    @Published private(set) var screenColorSample: ScreenColorSample?
    private var screenColorSampler: NSColorSampler?

    var isSamplingScreenColor: Bool { interactionState.isSamplingScreenColor }

    @Published private(set) var display: NotchDisplay?
    @Published private var openHeight = openNotchSize.height
    private(set) var expansionCycle = 0
    var diagnosticID: String { interaction.diagnosticID }
    var measuredPanelHeight: CGFloat?
    var measuredMusicContentHeight: CGFloat?
    private let defaultClosedNotchSize = getClosedNotchSize()

    var closedNotchSize: CGSize { display?.closedNotchSize ?? defaultClosedNotchSize }

    var notchSize: CGSize {
        notchState == .open ? CGSize(width: openNotchSize.width, height: openHeight) : closedNotchSize
    }
    
    let webcamManager = WebcamManager.shared
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false
    
    // No deinit needed — each AnyCancellable cancels itself when deallocated.
    // `destroy()` is available for callers that want to force teardown earlier
    // (e.g. when the associated window closes before the VM is released).

    func destroy() {
        cancelPanelTimers()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    override init() {
        animation = animationLibrary.animation
        super.init()
        setupDetectorObserver()
    }

    func updateDisplay(_ display: NotchDisplay?) {
        guard self.display != display else { return }
        let moved = self.display?.uuid != display?.uuid || self.display?.notchAnchor != display?.notchAnchor
        self.display = display
        NotchDiagnostics.logger.notice("""
            panel=\(self.diagnosticID, privacy: .public) event=display_changed \
            connected=\(display != nil) width_pt=\(Double(display?.frame.width ?? 0)) \
            height_pt=\(Double(display?.frame.height ?? 0)) physical_notch=\(display?.hasPhysicalNotch == true) \
            menu_bar_height_pt=\(Double(display?.menuBarHeight ?? 0))
            """)
        if moved {
            interaction.panelMoved()
        }
        if display == nil {
            cancelPanelTimers()
            isTextInputFocused = false
        }
    }
    
    private func setupDetectorObserver() {
        // Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        let screenPublisher = $display
            .map { $0?.uuid }
            .removeDuplicates()

        // Publisher for fullscreen status dictionary
        let fullscreenStatusPublisher = detector.$fullscreenStatus
            .removeDuplicates()

        // Combine all three: screen UUID, fullscreen status, and enabled setting
        Publishers.CombineLatest3(screenPublisher, fullscreenStatusPublisher, enabledPublisher)
            .map { screenUUID, fullscreenStatus, enabled in
                let isFullscreen = screenUUID.flatMap { fullscreenStatus[$0] } ?? false
                return enabled && isFullscreen
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let noNotchAndFullscreen = hideOnClosed && display?.hasPhysicalNotch != true
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    var chinHeight: CGFloat {
        if !Defaults[.hideTitleBar] {
            return 0
        }

        guard let display else {
            return 0
        }

        if notchState == .open { return 0 }

        let currentHeight = effectiveClosedNotchHeight

        if currentHeight == 0 { return 0 }

        return max(0, display.menuBarHeight - currentHeight)
    }

    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
                isCameraExpanded = false
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
                isCameraExpanded = true
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRequestingAuthorization = false
            }

        default:
            break
        }
    }
    
    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        if let frame = display?.frame {
            
            let baseY = frame.maxY - notchSize.height
            let baseX = frame.midX - notchSize.width / 2
            
            return position.y >= baseY && position.y <= frame.maxY
                && position.x >= baseX && position.x <= baseX + notchSize.width
        }
        
        return false
    }

    func open() {
        interaction.open()
    }

    func toggleFromShortcut() {
        interaction.toggleFromShortcut()
        makePanelKeyForKeyboardInput()
    }

    func toggleTabFromShortcut(_ tab: NotchViews) {
        guard coordinator.tabLayout.isVisible(tab) else { return }
        if notchState == .open && coordinator.currentView == tab {
            NotchDiagnostics.logger.notice("panel=\(self.diagnosticID, privacy: .public) event=tab_shortcut_close")
            close()
            return
        }

        if coordinator.currentView != tab {
            coordinator.currentView = tab
        }
        interaction.openFromTabShortcut()
        makePanelKeyForKeyboardInput()
    }

    @discardableResult
    func dismissFromEscape() -> Bool {
        interaction.dismissFromEscape()
    }

    func hoverChanged(_ hovering: Bool) {
        interaction.hoverChanged(hovering)
    }

    func setScreenshotCaptureActive(_ active: Bool) {
        interaction.setScreenshotCaptureActive(active)
    }

    func setTodoReordering(_ active: Bool) {
        interaction.setTodoReordering(active)
    }

    func pickScreenColor() {
        guard notchState == .open, screenColorSampler == nil else { return }
        let sampler = NSColorSampler()
        screenColorSampler = sampler
        interaction.setScreenColorSampling(true)
        sampler.show { [weak self] color in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let color, let sample = ScreenColorSample(color) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(sample.hex, forType: .string)
                    self.screenColorSample = sample
                }
                self.screenColorSampler = nil
                self.interaction.setScreenColorSampling(false)
            }
        }
    }

    func cancelPanelTimers() {
        interaction.cancelPendingTransitions()
    }

    func setOpenNotchHeight(_ height: CGFloat, minimum: CGFloat = openNotchSize.height) {
        guard notchState == .open else { return }
        let clampedHeight = min(max(height, minimum), sevenIslandFeatureNotchHeight)
        guard abs(openHeight - clampedHeight) > 0.5 else { return }
        openHeight = clampedHeight
    }

    func resetOpenNotchSize() {
        setOpenNotchHeight(openNotchSize.height)
    }

    func closeUnlessPinned() {
        interaction.closeUnlessPinned()
    }

    func close() {
        let wasClosed = notchState == .closed
        interaction.close()
        if wasClosed {
            applyClosedEffects()
        }
    }

    private func applyInteractionState(_ state: NotchInteraction.State) {
        let visibilityChanged = state.notchState != notchState
        if visibilityChanged {
            switch state.notchState {
            case .open:
                expansionCycle += 1
                openHeight = openNotchSize.height
                measuredMusicContentHeight = nil
            case .closed: applyClosedEffects()
            }
        }
        interactionState = state
        guard visibilityChanged else { return }
        let phase = state.notchState == .open ? "open" : "closed"
        NotchDiagnostics.logger.notice("""
            panel=\(self.diagnosticID, privacy: .public) event=panel_state state=\(phase, privacy: .public) \
            cycle=\(self.expansionCycle) tab=\(self.coordinator.currentView.rawValue, privacy: .public) \
            target_height_pt=\(Double(self.notchSize.height)) first_launch=\(self.coordinator.firstLaunch) \
            welcome_animation=\(self.coordinator.helloAnimationRunning)
            """)
        if state.notchState == .open {
            MusicManager.shared.forceUpdate()
        } else {
            releasePanelKeyForKeyboardInput()
        }
    }

    private func releasePanelKeyForKeyboardInput() {
        guard didMakePanelKeyForKeyboardInput else { return }
        didMakePanelKeyForKeyboardInput = false
        guard let panelWindow, panelWindow.isKeyWindow else { return }
        panelWindow.makeFirstResponder(nil)
        panelWindow.orderOut(nil)
        panelWindow.orderFrontRegardless()
    }

    private func applyClosedEffects() {
        coordinator.sneakPeek.show = false
        edgeAutoOpenActive = false
    }

    func closeHello() {
        Task { @MainActor in
            withAnimation(animationLibrary.animation) {
                coordinator.helloAnimationRunning = false
                close()
            }
        }
    }
}
