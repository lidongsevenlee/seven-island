//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            Button("设置") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            Button("区域截图") {
                appDelegate.startScreenshotFromMenu()
            }
            CheckForUpdatesView(updater: updaterController.updater)
            Divider()
            Button("重启") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private let notchWindows = NotchWindowManager { BoringNotchSkyLightWindow(viewModel: $0) }
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private weak var trackingMenu: NSMenu?
    private var isScreenLocked = false
    private var unlockTask: Task<Void, Never>?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        unlockTask?.cancel()
        notchWindows.removeAll()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
    }

    private func onScreenLocked() {
        ScreenshotTool.shared.cancelCapture()
        unlockTask?.cancel()
        unlockTask = nil
        isScreenLocked = true
        refreshNotchWindows()
    }

    private func onScreenUnlocked() {
        isScreenLocked = false
        unlockTask?.cancel()
        if Defaults[.showOnLockScreen] {
            unlockTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                self.unlockTask = nil
                self.refreshNotchWindows()
            }
        } else {
            unlockTask = nil
            refreshNotchWindows()
        }
    }

    func startScreenshotFromMenu() {
        trackingMenu?.cancelTracking()
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            Task { @MainActor in
                guard self?.isScreenLocked == false else { return }
                ScreenshotTool.shared.startCapture()
            }
        }
    }

    @objc private func menuTrackingDidBegin(_ notification: Notification) {
        trackingMenu = notification.object as? NSMenu
    }

    @objc private func menuTrackingDidEnd(_ notification: Notification) {
        if let menu = notification.object as? NSMenu, menu === trackingMenu {
            trackingMenu = nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ClipboardHistoryStore.shared

        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingDidBegin),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingDidEnd),
                                               name: NSMenu.didEndTrackingNotification, object: nil)

        let windowConfigurationNotifications: [Notification.Name] = [
            NSApplication.didChangeScreenParametersNotification,
            .selectedScreenChanged,
            .notchHeightChanged,
            .automaticallySwitchDisplayChanged,
            .showOnAllDisplaysChanged
        ]
        for name in windowConfigurationNotifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(notchConfigurationDidChange), name: name, object: nil
            )
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.onScreenLocked()
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.onScreenUnlocked()
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { @MainActor in
                self?.notchWindows.togglePanel(at: NSEvent.mouseLocation)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .captureScreenshot) { [weak self] in
            Task { @MainActor in
                guard self?.isScreenLocked == false else { return }
                ScreenshotTool.shared.toggleCapture()
            }
        }

        refreshNotchWindows()

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController].usesSystemPlayback
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc private func notchConfigurationDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            if notification.name == NSApplication.didChangeScreenParametersNotification {
                ScreenshotTool.shared.cancelCapture()
            }
            self?.refreshNotchWindows()
        }
    }

    private func refreshNotchWindows() {
        let displays: [NotchDisplay] = NSScreen.screens.compactMap { screen in
            guard let uuid = screen.displayUUID else { return nil }
            return NotchDisplay(
                uuid: uuid,
                frame: screen.frame,
                closedNotchSize: getClosedNotchSize(on: screen),
                menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
                hasPhysicalNotch: screen.safeAreaInsets.top > 0
            )
        }
        let mode: NotchWindowManager.Mode = Defaults[.showOnAllDisplays]
            ? .allDisplays
            : .singleDisplay(
                preferred: coordinator.preferredScreenUUID,
                fallback: Defaults[.automaticallySwitchDisplay] ? NSScreen.main?.displayUUID : nil
            )

        let presentation: NotchWindowManager.Presentation
        if isScreenLocked {
            presentation = Defaults[.showOnLockScreen] ? .lockScreen : .hidden
        } else {
            presentation = unlockTask == nil ? .desktop : .lockScreen
        }
        notchWindows.reconcile(displays: displays, mode: mode, presentation: presentation)
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
}
