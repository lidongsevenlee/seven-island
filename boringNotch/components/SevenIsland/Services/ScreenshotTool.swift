import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
struct CapturedScreenshot {
    let png: Data
    let image: NSImage

    init?(image: CGImage, size: CGSize) {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        self.png = png
        self.image = NSImage(cgImage: image, size: size)
    }

    func fittedSize(in available: CGSize) -> CGSize {
        let size = image.size
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
    private var pinnedPanels: [NSPanel] = []
    private var savePanel: NSSavePanel?

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
        preparation = Task {
            defer { preparation = nil }
            let authorized = await Task.detached { CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }.value
            guard !Task.isCancelled else { return }
            guard authorized else {
                showPermissionNotice()
                return
            }

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
                if CGPreflightScreenCaptureAccess() {
                    showNotice("截图失败，请重试。")
                } else {
                    showPermissionNotice()
                }
            }
        }
    }

    func cancelCapture() {
        preparation?.cancel()
        let windows = overlays
        overlays.removeAll()
        activeOverlay = nil
        windows.forEach { $0.close() }
    }

    private func captureDisplays(frontmostPID: pid_t?) async throws -> [ScreenshotDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == ownProcess }
        let candidates = content.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.processID != ownProcess
                && $0.frame.width >= 40 && $0.frame.height >= 40
        }
        let frontToBackIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]])?.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value } ?? []
        let windowsByID = Dictionary(candidates.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedWindows = frontToBackIDs.compactMap { windowsByID[$0] }

        var captures: [ScreenshotDisplay] = []
        for screen in NSScreen.screens {
            try Task.checkCancellation()
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else { continue }

            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            configuration.width = Int((screen.frame.width * CGFloat(filter.pointPixelScale)).rounded())
            configuration.height = Int((screen.frame.height * CGFloat(filter.pointPixelScale)).rounded())
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let visibleWindows = orderedWindows.compactMap { window -> (pid_t?, CGRect)? in
                let clip = window.frame.intersection(display.frame)
                guard !clip.isEmpty else { return nil }
                return (window.owningApplication?.processID, clip.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY))
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

        cancelCapture()
        switch action {
        case .copy:
            if !screenshot.copy(to: .general) { showNotice("复制截图失败，请重试。") }
        case .save:
            save(screenshot)
        case .pin:
            let center = CGPoint(x: display.frame.minX + selection.midX, y: display.frame.maxY - selection.midY)
            pin(screenshot, near: center)
        }
    }

    private func save(_ screenshot: CapturedScreenshot) {
        let panel = NSSavePanel()
        savePanel = panel
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let timestamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "")
        panel.nameFieldStringValue = "截图 \(timestamp)"
        panel.prompt = "保存"
        NSApp.activate()
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            defer { self.savePanel = nil }
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
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "悬浮截图"
        panel.animationBehavior = .none
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        let x = max(screen.minX, min(point.x - panel.frame.width / 2, screen.maxX - panel.frame.width))
        let y = max(screen.minY, min(point.y - panel.frame.height / 2, screen.maxY - panel.frame.height))
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        let imageView = FloatingScreenshotView(image: screenshot.image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1 / panel.backingScaleFactor
        imageView.layer?.borderColor = NSColor(white: 1, alpha: 0.4).cgColor
        imageView.setAccessibilityLabel("悬浮截图，双击关闭")
        panel.contentView = imageView
        pinnedPanels.append(panel)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        pinnedPanels.removeAll { $0 === panel }
    }

    private func showPermissionNotice() {
        let alert = NSAlert()
        alert.messageText = "截图需要屏幕录制权限"
        alert.informativeText = "在「屏幕与系统音频录制」中允许 Seven Island，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(settings)
        }
    }

    private func showNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        NSApp.activate()
        alert.runModal()
    }
}

private final class FloatingScreenshotView: NSImageView {
    private var dragStart: (pointer: CGPoint, origin: CGPoint)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.close()
            return
        }
        guard let window else { return }
        dragStart = (pointer: NSEvent.mouseLocation, origin: window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let pointer = NSEvent.mouseLocation
        window?.setFrameOrigin(CGPoint(
            x: dragStart.origin.x + pointer.x - dragStart.pointer.x,
            y: dragStart.origin.y + pointer.y - dragStart.pointer.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}
