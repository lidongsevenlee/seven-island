import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
struct CapturedScreenshot {
    let png: Data
    let image: CGImage
    let size: CGSize

    init?(image: CGImage, size: CGSize) {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        self.png = png
        self.image = image
        self.size = size
    }

    func fittedSize(in available: CGSize) -> CGSize {
        let scale = min(available.width / size.width, available.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func copy(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
    }

    func save(to url: URL) throws {
        try png.write(to: url, options: .atomic)
    }
}

struct ScreenshotDisplay {
    let frame: CGRect
    let image: CGImage
    let windowRegions: [CGRect]
    let frontmostWindowRegion: CGRect?

    var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }
    var pixelBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    func suggestedRegion(at point: CGPoint) -> CGRect {
        windowRegions.first { $0.contains(point) } ?? bounds
    }

    func pixel(at point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, floor(point.x * pixelBounds.width / bounds.width)), pixelBounds.maxX - 1),
                y: min(max(0, floor(point.y * pixelBounds.height / bounds.height)), pixelBounds.maxY - 1))
    }

    func pixelRect(for selection: CGRect) -> CGRect {
        let points = selection.intersection(bounds)
        guard !points.isNull else { return .null }
        let x = CGFloat(image.width) / frame.width
        let y = CGFloat(image.height) / frame.height
        return CGRect(x: points.minX * x, y: points.minY * y, width: points.width * x, height: points.height * y)
            .integral.intersection(pixelBounds)
    }
}

@MainActor
final class ScreenshotTool: NSObject, NSWindowDelegate {
    enum Action { case copy, save, pin }

    static let shared = ScreenshotTool()

    private var preparation: Task<Void, Never>?
    private var overlays: [ScreenshotSelectionPanel] = []
    private weak var activeOverlay: ScreenshotSelectionPanel?
    private var pinnedPanels: [FloatingScreenshotPanel] = []
    private var savePanel: NSSavePanel?
    private let suspendedNotchPanels = NSHashTable<BoringNotchSkyLightWindow>.weakObjects()
    private weak var keyWindowBeforeCapture: NSWindow?

    private var visibleNotchPanels: [BoringNotchSkyLightWindow] {
        NSApp.windows.compactMap { $0 as? BoringNotchSkyLightWindow }.filter(\.isVisible)
    }

    func toggleCapture() {
        if preparation != nil || !overlays.isEmpty {
            cancelCapture()
            return
        }
        startCapture()
    }

    func startCapture() {
        guard preparation == nil, overlays.isEmpty, savePanel == nil else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        suspendNotchPanels()
        preparation = Task {
            defer {
                preparation = nil
                if overlays.isEmpty && savePanel == nil { resumeNotchPanels() }
            }
            let authorized = await Self.authorizeCapture(
                preflight: { await Task.detached { CGPreflightScreenCaptureAccess() }.value },
                confirmRequest: { showPermissionNotice(canRequest: true) },
                request: { await Task.detached { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }.value }
            )
            guard authorized, !Task.isCancelled else { return }

            do {
                let displays = try await captureDisplays(frontmostPID: frontmostPID)
                guard !Task.isCancelled else { return }
                guard !displays.isEmpty else {
                    showNotice("无法获取屏幕画面，请重试。")
                    return
                }
                showSelection(displays)
            } catch {
                guard !Task.isCancelled else { return }
                if (error as? SCStreamError)?.code == .userDeclined || !CGPreflightScreenCaptureAccess() {
                    showPermissionNotice(canRequest: false)
                } else {
                    showNotice("截图失败，请重试。")
                }
            }
        }
    }

    static func authorizeCapture(
        preflight: () async -> Bool, confirmRequest: () -> Bool, request: () async -> Bool
    ) async -> Bool {
        let alreadyAuthorized = await preflight()
        guard !Task.isCancelled else { return false }
        if alreadyAuthorized { return true }
        guard confirmRequest(), !Task.isCancelled else { return false }
        return await request()
    }

    func cancelCapture() {
        preparation?.cancel()
        closeSelection()
        resumeNotchPanels()
    }

    private func closeSelection() {
        let windows = overlays
        overlays.removeAll()
        activeOverlay = nil
        windows.forEach { $0.close() }
    }

    private func suspendNotchPanels() {
        if suspendedNotchPanels.allObjects.isEmpty {
            keyWindowBeforeCapture = NSApp.keyWindow
        }
        for panel in visibleNotchPanels where panel.expandedContentSize != nil && !suspendedNotchPanels.contains(panel) {
            suspendedNotchPanels.add(panel)
            panel.setScreenshotCaptureActive(true)
        }
    }

    private func resumeNotchPanels() {
        let panels = suspendedNotchPanels.allObjects
        let previousKey = keyWindowBeforeCapture
        suspendedNotchPanels.removeAllObjects()
        keyWindowBeforeCapture = nil
        guard !panels.isEmpty else { return }
        panels.forEach { $0.setScreenshotCaptureActive(false) }

        if let keyWindow = NSApp.keyWindow ?? previousKey, !(keyWindow is BoringNotchSkyLightWindow) { return }
        let remaining = panels.filter { $0.isVisible && $0.expandedContentSize != nil }
        let target = remaining.first { $0 === previousKey } ?? remaining.first(where: \.isPointerOverPanel)
        target?.restoreKeyboardFocus()
    }

    func windowsExcludedFromCapture(in windows: [SCWindow], notchPanelIDs: Set<CGWindowID>,
                                    settingsWindowID: CGWindowID?) -> [SCWindow] {
        var preservedIDs = notchPanelIDs.union(pinnedPanels.flatMap(\.captureWindowIDs))
        if let settingsWindowID { preservedIDs.insert(settingsWindowID) }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        return windows.filter {
            $0.owningApplication?.processID == ownProcess && !preservedIDs.contains($0.windowID)
        }
    }

    private func captureDisplays(frontmostPID: pid_t?) async throws -> [ScreenshotDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let islandPanels = visibleNotchPanels.filter { $0.sharingType != .none }
        let panelsByID = Dictionary(uniqueKeysWithValues: islandPanels.map { (CGWindowID($0.windowNumber), $0) })
        let calendarWindowIDs = islandPanels.flatMap(\.todoCalendarPanels).compactMap { panel -> CGWindowID? in
            guard panel.isVisible, panel.sharingType != .none else { return nil }
            return CGWindowID(exactly: panel.windowNumber)
        }
        let settingsWindowID = SettingsWindowController.shared.window.flatMap { window -> CGWindowID? in
            guard window.isVisible, !window.isMiniaturized, window.sharingType != .none else { return nil }
            return CGWindowID(exactly: window.windowNumber)
        }
        let excludedWindows = windowsExcludedFromCapture(
            in: content.windows, notchPanelIDs: Set(panelsByID.keys).union(calendarWindowIDs),
            settingsWindowID: settingsWindowID
        )
        let windowRegions = content.windows.compactMap { window -> (CGWindowID, (pid_t?, CGRect))? in
            let pid = window.owningApplication?.processID
            let frame = window.frame
            if let size = panelsByID[window.windowID]?.expandedContentSize {
                let region = CGRect(x: frame.midX - size.width / 2, y: frame.minY,
                                    width: size.width, height: size.height)
                return (window.windowID, (pid, region))
            }
            guard window.windowLayer == 0, pid != ownProcess || window.windowID == settingsWindowID,
                  frame.width >= 40, frame.height >= 40 else { return nil }
            return (window.windowID, (pid, frame))
        }
        let frontToBackIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]])?.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value } ?? []
        let regionsByID = Dictionary(windowRegions, uniquingKeysWith: { first, _ in first })
        let orderedRegions = frontToBackIDs.compactMap { regionsByID[$0] }

        var captures: [ScreenshotDisplay] = []
        for screen in NSScreen.screens {
            try Task.checkCancellation()
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            configuration.width = Int((screen.frame.width * CGFloat(filter.pointPixelScale)).rounded())
            configuration.height = Int((screen.frame.height * CGFloat(filter.pointPixelScale)).rounded())
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let visibleWindows = orderedRegions.compactMap { pid, region -> (pid_t?, CGRect)? in
                let clip = region.intersection(display.frame)
                guard !clip.isEmpty else { return nil }
                return (pid, clip.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY))
            }
            let frontmost = frontmostPID == nil || frontmostPID == ownProcess
                ? visibleWindows.first?.1
                : visibleWindows.first(where: { $0.0 == frontmostPID })?.1
            captures.append(ScreenshotDisplay(frame: screen.frame, image: image, windowRegions: visibleWindows.map(\.1),
                                              frontmostWindowRegion: frontmost))
        }
        return captures
    }

    func showSelection(_ displays: [ScreenshotDisplay]) {
        guard !displays.isEmpty, overlays.isEmpty else { return }
        suspendNotchPanels()
        overlays = displays.map { display in
            ScreenshotSelectionPanel(display: display, activate: { [weak self] panel in
                self?.activate(panel) ?? false
            }, finish: { [weak self] action, rect, image in
                self?.finish(action, selection: rect, image: image, on: display)
            }, cancel: { [weak self] in
                self?.cancelCapture()
            })
        }
        let pointer = NSEvent.mouseLocation
        activeOverlay = overlays.first(where: { $0.frame.contains(pointer) }) ?? overlays.first
        activeOverlay?.updatePointer(at: pointer)
        overlays.forEach { $0.orderFrontRegardless() }
        overlays.forEach { $0.revealPreparedFrame() }
        activeOverlay?.makeKey()
    }

    private func activate(_ panel: ScreenshotSelectionPanel) -> Bool {
        guard activeOverlay !== panel else { return true }
        guard activeOverlay?.locksDisplay != true else { return false }
        activeOverlay?.deactivate()
        activeOverlay = panel
        panel.makeKey()
        return true
    }

    private func finish(_ action: Action, selection: CGRect, image: CGImage?, on display: ScreenshotDisplay) {
        guard let image, let screenshot = CapturedScreenshot(image: image, size: selection.size) else {
            cancelCapture()
            showNotice("生成截图失败，请重试。")
            return
        }

        closeSelection()
        switch action {
        case .copy:
            copy(screenshot)
            resumeNotchPanels()
        case .save:
            save(screenshot)
        case .pin:
            let center = CGPoint(x: display.frame.minX + selection.midX, y: display.frame.maxY - selection.midY)
            pin(screenshot, near: center)
            resumeNotchPanels()
        }
    }

    private func copy(_ screenshot: CapturedScreenshot) {
        if !screenshot.copy(to: .general) { showNotice("复制截图失败，请重试。") }
    }

    private func save(_ screenshot: CapturedScreenshot) {
        if let savePanel {
            savePanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSSavePanel()
        savePanel = panel
        panel.level = .modalPanel
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let timestamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "")
        panel.nameFieldStringValue = "截图 \(timestamp)"
        panel.prompt = "保存"
        NSApp.activate()
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            defer {
                self.savePanel = nil
                self.resumeNotchPanels()
            }
            guard response == .OK, let url = panel?.url else { return }
            do {
                try screenshot.save(to: url)
            } catch {
                self.showNotice("保存失败，请检查目标文件夹后重试。")
            }
        }
    }

    func pin(_ screenshot: CapturedScreenshot, near point: CGPoint) {
        let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = screenshot.fittedSize(in: CGSize(width: screen.width * 0.85, height: screen.height * 0.85))
        let x = max(screen.minX, min(point.x - size.width / 2, screen.maxX - size.width))
        let y = max(screen.minY, min(point.y - size.height / 2, screen.maxY - size.height))
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        let panel = FloatingScreenshotPanel(screenshot: screenshot, frame: frame) { [weak self] action, image in
            guard let self else { return }
            guard let image, let edited = CapturedScreenshot(image: image, size: screenshot.size) else {
                showNotice("生成截图失败，请重试。")
                return
            }
            switch action {
            case .copy: copy(edited)
            case .save: save(edited)
            case .pin: break
            }
        }
        panel.delegate = self
        pinnedPanels.append(panel)
        panel.showPin()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? FloatingScreenshotPanel else { return }
        pinnedPanels.removeAll { $0 === panel }
    }

    @discardableResult
    private func showPermissionNotice(canRequest: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "截图需要屏幕录制权限"
        alert.informativeText = "在「屏幕与系统音频录制」中允许 Seven Island，然后重新打开应用。更新后若授权仍不可用，请移除旧条目，再添加「应用程序」中的 Seven Island。"
        alert.addButton(withTitle: "打开系统设置")
        if canRequest { alert.addButton(withTitle: "请求系统授权") }
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        let action = alert.runModal()
        if action == .alertFirstButtonReturn {
            let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(settings)
        }
        return canRequest && action == .alertSecondButtonReturn
    }

    private func showNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        NSApp.activate()
        alert.runModal()
    }
}
