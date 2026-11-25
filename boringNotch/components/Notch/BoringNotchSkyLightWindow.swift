//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine
import SwiftUI

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    private weak var viewModel: BoringViewModel?

    var expandedContentSize: CGSize? {
        guard let viewModel, viewModel.notchState == .open else { return nil }
        return viewModel.notchSize
    }

    var isPointerOverPanel: Bool { viewModel?.isMouseHovering() == true }

    var todoCalendarPanels: [TodoCalendarPanel] {
        (childWindows ?? []).compactMap { $0 as? TodoCalendarPanel }
    }

    func setScreenshotCaptureActive(_ active: Bool) {
        viewModel?.setScreenshotCaptureActive(active)
    }

    func restoreKeyboardFocus() {
        viewModel?.makePanelKeyForKeyboardInput()
    }
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        // SwiftUI animates the panel while AppKit hands keyboard focus back.
        animationBehavior = .none
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
        for calendar in todoCalendarPanels {
            calendar.sharingType = sharingType
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if viewModel?.dismissFromEscape() != true {
            super.cancelOperation(sender)
        }
    }
}

extension BoringNotchSkyLightWindow: NotchPanelWindow {
    convenience init(viewModel: BoringViewModel) {
        self.init(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        self.viewModel = viewModel
        viewModel.panelWindow = self
        contentView = NSHostingView(rootView: ContentView().environmentObject(viewModel))
    }

    func show(at notchAnchor: CGPoint, onLockScreen: Bool) {
        let origin = CGPoint(x: notchAnchor.x - frame.width / 2, y: notchAnchor.y - frame.height)
        if frame.origin != origin {
            setFrameOrigin(origin)
        }

        if onLockScreen {
            enableSkyLight()
        } else {
            disableSkyLight()
        }

        if !isVisible {
            orderFrontRegardless()
        }
        let space = NotchSpaceManager.shared.notchSpace
        if !space.windows.contains(self) {
            space.windows.insert(self)
        }
    }

    func hide() {
        leaveNotchSpaces()
        orderOut(nil)
    }

    func dispose() {
        leaveNotchSpaces()
        close()
    }

    private func leaveNotchSpaces() {
        disableSkyLight()
        let space = NotchSpaceManager.shared.notchSpace
        if space.windows.contains(self) {
            space.windows.remove(self)
        }
    }
}
