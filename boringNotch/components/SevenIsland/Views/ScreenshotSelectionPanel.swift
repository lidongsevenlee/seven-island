import AppKit
import Carbon
import SwiftUI

@MainActor
final class ScreenshotSelectionPanel: NSPanel {
    private let canvas: ScreenshotSelectionCanvas

    init(display: ScreenshotDisplay, activate: @escaping (ScreenshotSelectionPanel) -> Bool,
         finish: @escaping (ScreenshotTool.Action, CGRect, CGImage?) -> Void, cancel: @escaping () -> Void) {
        let canvas = ScreenshotSelectionCanvas(display: display, finish: finish, cancel: cancel)
        self.canvas = canvas
        super.init(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "区域截图"
        level = .screenSaver
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        acceptsMouseMovedEvents = true
        contentView = canvas
        canvas.activateDisplay = { [weak self] in
            guard let self else { return false }
            return activate(self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var locksDisplay: Bool { canvas.locksDisplay }

    func updatePointer(at point: CGPoint) {
        canvas.updatePointer(CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y))
    }

    func revealPreparedFrame() {
        canvas.layoutSubtreeIfNeeded()
        displayIfNeeded()
        alphaValue = 1
    }

    func deactivate() {
        canvas.deactivate()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, canvas.handleKey(event) { return }
        super.sendEvent(event)
    }
}

@MainActor
final class FloatingScreenshotPanel: NSPanel {
    private let canvas: ScreenshotSelectionCanvas
    private var toolbarPanel: NSPanel?
    private let toolbarMenuItem = NSMenuItem(title: "显示工具条", action: #selector(toggleToolbar), keyEquivalent: "")

    init(screenshot: CapturedScreenshot, frame: CGRect, perform: @escaping (ScreenshotTool.Action, CGImage?) -> Void) {
        let display = ScreenshotDisplay(frame: frame, image: screenshot.image, windowRegions: [], frontmostWindowRegion: nil)
        canvas = ScreenshotSelectionCanvas(display: display, isFloating: true, finish: { action, _, image in
            perform(action, image)
        }, cancel: {})
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "悬浮截图"
        animationBehavior = .none
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 5
        canvas.layer?.masksToBounds = true
        canvas.layer?.borderWidth = 1 / backingScaleFactor
        canvas.layer?.borderColor = NSColor(white: 1, alpha: 0.4).cgColor
        canvas.setAccessibilityLabel("悬浮截图，双击关闭")
        canvas.onFloatingToolbarLayout = { [weak self] in self?.layoutToolbar() }
        canvas.onFloatingToolbarDismiss = { [weak self] in self?.hideToolbar() }
        canvas.menu = contextMenu()
        contentView = canvas
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var canBecomeKey: Bool { toolbarPanel != nil }

    override func sendEvent(_ event: NSEvent) {
        if toolbarPanel != nil, event.type == .keyDown, canvas.handleKey(event) { return }
        super.sendEvent(event)
    }

    override func close() {
        hideToolbar()
        super.close()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let items = [
            NSMenuItem(title: "复制", action: #selector(copyImage), keyEquivalent: ""),
            NSMenuItem(title: "保存", action: #selector(saveImage), keyEquivalent: ""),
            NSMenuItem(title: "销毁", action: #selector(destroyImage), keyEquivalent: ""),
            toolbarMenuItem
        ]
        for item in items {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func copyImage() { canvas.submit(.copy) }
    @objc private func saveImage() { canvas.submit(.save) }
    @objc private func destroyImage() { close() }

    @objc private func toggleToolbar() {
        if toolbarPanel != nil {
            hideToolbar()
            return
        }
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: canvas.floatingToolbarSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = collectionBehavior
        panel.contentView = canvas.floatingToolbarView
        toolbarPanel = panel
        toolbarMenuItem.title = "隐藏工具条"
        layoutToolbar()
        addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        makeKey()
        makeFirstResponder(canvas)
    }

    private func hideToolbar() {
        guard let panel = toolbarPanel else { return }
        toolbarPanel = nil
        toolbarMenuItem.title = "显示工具条"
        canvas.endFloatingEditing()
        removeChildWindow(panel)
        panel.close()
        panel.contentView = nil
    }

    private func layoutToolbar() {
        guard let toolbarPanel else { return }
        let size = canvas.floatingToolbarSize
        let gap: CGFloat = 7
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? frame.insetBy(dx: -size.width, dy: -size.height - gap)
        let x = max(area.minX, min(frame.maxX - size.width, area.maxX - size.width))
        let below = frame.minY - size.height - gap
        let above = frame.maxY + gap
        let y = below >= area.minY ? below : min(above, area.maxY - size.height)
        let toolbarFrame = CGRect(origin: CGPoint(x: x, y: max(area.minY, y)), size: size)
        if toolbarPanel.frame != toolbarFrame {
            toolbarPanel.setFrame(toolbarFrame, display: true)
        }
    }
}

struct ScreenshotResizeHandle {
    enum Axis {
        case minimum, middle, maximum

        func position(in range: ClosedRange<CGFloat>) -> CGFloat {
            switch self {
            case .minimum: range.lowerBound
            case .middle: (range.lowerBound + range.upperBound) / 2
            case .maximum: range.upperBound
            }
        }

        func resized(_ range: ClosedRange<CGFloat>, by offset: CGFloat,
                     within limits: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
            guard self != .middle else { return range }
            let fixed = self == .minimum ? range.upperBound : range.lowerBound
            let moving = min(max(position(in: range) + offset, limits.lowerBound), limits.upperBound)
            return min(fixed, moving)...max(fixed, moving)
        }
    }

    let x: Axis
    let y: Axis

    static let all: [Self] = [
        .init(x: .minimum, y: .minimum), .init(x: .middle, y: .minimum), .init(x: .maximum, y: .minimum),
        .init(x: .maximum, y: .middle), .init(x: .maximum, y: .maximum), .init(x: .middle, y: .maximum),
        .init(x: .minimum, y: .maximum), .init(x: .minimum, y: .middle)
    ]

    func position(in region: CGRect) -> CGPoint {
        CGPoint(x: x.position(in: region.minX...region.maxX), y: y.position(in: region.minY...region.maxY))
    }

    func resize(_ region: CGRect, by offset: CGVector, within bounds: CGRect) -> CGRect {
        let horizontal = x.resized(region.minX...region.maxX, by: offset.dx, within: bounds.minX...bounds.maxX)
        let vertical = y.resized(region.minY...region.maxY, by: offset.dy, within: bounds.minY...bounds.maxY)
        return CGRect(x: horizontal.lowerBound, y: vertical.lowerBound,
                      width: horizontal.upperBound - horizontal.lowerBound, height: vertical.upperBound - vertical.lowerBound)
    }
}

@MainActor
private final class ScreenshotSelectionCanvas: NSView, NSTextFieldDelegate {
    private enum Drag {
        case create(CGPoint)
        case move(start: CGPoint, original: CGRect)
        case resize(handle: ScreenshotResizeHandle, start: CGPoint, original: CGRect)
        case moveWindow(pointer: CGPoint, origin: CGPoint)
    }

    private struct SizeBadge {
        let label: NSAttributedString
        let frame: CGRect
    }

    var activateDisplay: (() -> Bool)?
    var onFloatingToolbarLayout: (() -> Void)?
    var onFloatingToolbarDismiss: (() -> Void)?
    var locksDisplay: Bool { selection != nil || drag != nil }
    var floatingToolbarView: NSView { toolbar }
    var floatingToolbarSize: CGSize { toolbarState.size }

    private let display: ScreenshotDisplay
    private let isFloating: Bool
    private let backdrop: NSImage
    private let finish: (ScreenshotTool.Action, CGRect, CGImage?) -> Void
    private let cancel: () -> Void
    private var selection: CGRect?
    private var suggestedRegion: CGRect?
    private var pointer: CGPoint?
    private var drag: Drag?
    private var didDrag = false
    private var tracking: NSTrackingArea?
    private var drawnRegion: CGRect?
    private var drawnHandles = false
    private var drawnLens: CGRect?
    private var drawnSizeBadge: SizeBadge?
    private let annotationRenderer: ScreenshotAnnotationRenderer
    private let toolbarState: ScreenshotToolbarState
    private var history = ScreenshotAnnotationHistory()
    private var draft: ScreenshotAnnotation?
    private var textEditor: (field: NSTextField, point: CGPoint, style: ScreenshotAnnotation.Style)?
    private let selectionBlue = NSColor(srgbRed: 0.34, green: 0.57, blue: 1, alpha: 1)
    private let magnifierAccent = NSColor(srgbRed: 0.31, green: 0.85, blue: 0.81, alpha: 1)
    private let handleRadius: CGFloat = 3.5
    private let magnifierColumns = 17
    private let magnifierRows = 13
    private let magnifierPixelSize: CGFloat = 7
    private lazy var toolbar = NSHostingView(rootView: ScreenshotSelectionActions(
        state: toolbarState,
        select: { [weak self] tool in self?.selectTool(tool) },
        changeHistory: { [weak self] redo in self?.changeHistory(redo: redo) },
        perform: { [weak self] action in self?.submit(action) },
        cancel: { [weak self] in self?.dismiss() }
    ))

    private var currentRegion: CGRect? { selection ?? suggestedRegion }

    init(display: ScreenshotDisplay, isFloating: Bool = false,
         finish: @escaping (ScreenshotTool.Action, CGRect, CGImage?) -> Void,
         cancel: @escaping () -> Void) {
        self.display = display
        self.isFloating = isFloating
        toolbarState = ScreenshotToolbarState(isFloating: isFloating)
        annotationRenderer = ScreenshotAnnotationRenderer(display: display)
        backdrop = NSImage(cgImage: display.image, size: display.frame.size)
        self.finish = finish
        self.cancel = cancel
        super.init(frame: display.bounds)
        if isFloating {
            selection = display.bounds
            drawnRegion = selection
        } else {
            toolbar.isHidden = true
            addSubview(toolbar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isFloating && toolbarState.tool == nil ? .arrow : .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        backdrop.draw(in: display.bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if let region = drawnRegion, let context = NSGraphicsContext.current?.cgContext {
            annotationRenderer.draw(history.visible, draft: previewDraft, clippedTo: region, in: context)
        }
        if let region = drawnRegion, !isFloating {
            if region != display.bounds {
                let mask = NSBezierPath(rect: display.bounds)
                mask.appendRect(region)
                mask.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.36).setFill()
                mask.fill()
            }
            let border = NSBezierPath(rect: region.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            selectionBlue.setStroke()
            border.stroke()
        }
        if let pointer, let lens = drawnLens, lens.intersects(dirtyRect) {
            drawMagnifier(at: pointer, in: lens)
        }
        if let region = drawnRegion, drawnHandles {
            selectionBlue.setFill()
            NSColor.white.withAlphaComponent(0.93).setStroke()
            for handle in ScreenshotResizeHandle.all {
                let point = handleCenter(handle, in: region)
                let dot = NSBezierPath(ovalIn: CGRect(x: point.x - handleRadius, y: point.y - handleRadius,
                                                    width: handleRadius * 2, height: handleRadius * 2))
                dot.fill()
                dot.lineWidth = 1
                dot.stroke()
            }
        }
        if let badge = drawnSizeBadge {
            NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: badge.frame, xRadius: 5, yRadius: 5).fill()
            badge.label.draw(at: CGPoint(x: badge.frame.minX + 7, y: badge.frame.minY + 3))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isFloating || activateDisplay?() == true else { return }
        updatePointer(point(for: event))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        update()
    }

    func updatePointer(_ point: CGPoint) {
        pointer = display.bounds.contains(point) ? point : nil
        if isFloating {
            if draft?.tool == .polyline { invalidate(selection, padding: 0) }
            return
        }
        let isOnToolbar = !toolbar.isHidden && toolbar.frame.contains(point)
        if !isOnToolbar, selection == nil, drag == nil, let pointer,
           suggestedRegion.flatMap({ resizeHandle(at: pointer, in: $0) }) == nil {
            suggestedRegion = display.suggestedRegion(at: pointer)
        }
        (isOnToolbar ? NSCursor.arrow : .crosshair).set()
        if draft?.tool == .polyline { invalidate(selection, padding: 0) }
        update()
    }

    override func mouseDown(with event: NSEvent) {
        guard isFloating || activateDisplay?() == true else { return }
        if isFloating, toolbarState.tool == nil, let window {
            if event.clickCount == 2 {
                window.close()
            } else {
                drag = .moveWindow(pointer: NSEvent.mouseLocation, origin: window.frame.origin)
            }
            return
        }
        finishText()
        window?.makeFirstResponder(self)
        let point = point(for: event)
        pointer = point
        didDrag = false
        if !isFloating, let region = drawnRegion, let handle = resizeHandle(at: point, in: region) {
            commitDraft()
            drag = .resize(handle: handle, start: point, original: region)
        } else if let selection, selection.contains(point), let tool = toolbarState.tool {
            if tool == .text {
                beginText(at: point, in: selection)
            } else if tool == .polyline, draft != nil {
                if draft?.points.last != point { draft?.points.append(point) }
                if event.clickCount > 1 { commitDraft() }
            } else {
                draft = ScreenshotAnnotation(tool: tool, style: toolbarState.annotationStyle, points: [point])
            }
            annotationsChanged()
            return
        } else if let selection, selection != display.bounds, selection.contains(point) {
            drag = .move(start: point, original: selection)
        } else if toolbarState.tool != nil {
            return
        } else {
            drag = .create(point)
        }
        update()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = point(for: event)
        if let draft, draft.tool != .polyline {
            self.draft?.extend(to: point, constrained: event.modifierFlags.contains(.shift))
            annotationsChanged()
            return
        }
        guard let drag else { return }
        didDrag = true
        pointer = point
        switch drag {
        case let .create(origin):
            selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                               width: abs(origin.x - point.x), height: abs(origin.y - point.y))
        case let .move(start, original):
            selection = moved(original, dx: point.x - start.x, dy: point.y - start.y)
        case let .resize(handle, start, original):
            selection = handle.resize(original, by: CGVector(dx: point.x - start.x, dy: point.y - start.y),
                                      within: display.bounds)
        case let .moveWindow(pointer, origin):
            let mouse = NSEvent.mouseLocation
            window?.setFrameOrigin(CGPoint(x: origin.x + mouse.x - pointer.x, y: origin.y + mouse.y - pointer.y))
        }
        update()
    }

    override func mouseUp(with event: NSEvent) {
        if let draft {
            if draft.tool != .polyline {
                self.draft?.extend(to: point(for: event), constrained: event.modifierFlags.contains(.shift))
                commitDraft()
                annotationsChanged()
            }
            return
        }
        guard drag != nil else { return }
        if isFloating {
            drag = nil
            return
        }
        if case .create = drag, !didDrag, selection != display.bounds {
            selection = display.suggestedRegion(at: point(for: event))
        }
        if let selection, selection.width < 2 || selection.height < 2 {
            self.selection = nil
        }
        drag = nil
        update()
        if event.clickCount >= 2, toolbarState.tool == nil { submit(.copy) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if isFloating {
            super.rightMouseDown(with: event)
        } else if textEditor != nil {
            finishText()
        } else if draft != nil {
            commitDraft()
            annotationsChanged()
        } else if toolbarState.tool != nil {
            selectTool(nil)
        } else if selection == nil {
            cancel()
        } else {
            resetAnnotations()
            selection = nil
            drag = nil
            updatePointer(point(for: event))
        }
    }

    func deactivate() {
        resetAnnotations()
        selection = nil
        suggestedRegion = nil
        pointer = nil
        drag = nil
        update()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if textEditor != nil {
            switch Int(event.keyCode) {
            case kVK_Escape: finishText(discard: true)
            case kVK_Return, kVK_ANSI_KeypadEnter: finishText()
            default: return false
            }
            return true
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            dismiss()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if draft?.tool == .polyline {
                commitDraft()
                annotationsChanged()
            } else {
                submit(.copy)
            }
            return true
        case kVK_Tab:
            guard let tool = toolbarState.alternate else { return false }
            selectTool(tool)
            return true
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard !isFloating, let selection = currentRegion else { return false }
            let x = display.bounds.width / CGFloat(display.image.width)
            let y = display.bounds.height / CGFloat(display.image.height)
            let offsets = [kVK_LeftArrow: CGPoint(x: -x, y: 0), kVK_RightArrow: CGPoint(x: x, y: 0),
                           kVK_UpArrow: CGPoint(x: 0, y: -y), kVK_DownArrow: CGPoint(x: 0, y: y)]
            let offset = offsets[Int(event.keyCode)] ?? .zero
            self.selection = moved(selection, dx: offset.x, dy: offset.y)
            update()
            return true
        default:
            guard event.modifierFlags.contains(.command) else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a" where !isFloating:
                if event.modifierFlags.contains(.shift) { selectFrontmostWindow() }
                else { selectDisplay() }
            case "c": submit(.copy)
            case "s": submit(.save)
            case "t" where !isFloating: submit(.pin)
            case "z": changeHistory(redo: event.modifierFlags.contains(.shift))
            case "y": changeHistory(redo: true)
            default: return false
            }
            return true
        }
    }

    private func selectDisplay() {
        selection = display.bounds
        update()
    }

    private var previewDraft: ScreenshotAnnotation? {
        guard var draft, draft.tool == .polyline, let pointer else { return draft }
        draft.points.append(pointer)
        return draft
    }

    private func selectTool(_ tool: ScreenshotAnnotation.Tool?) {
        finishText()
        commitDraft()
        toolbarState.tool = tool
        window?.makeFirstResponder(self)
        annotationsChanged()
        if isFloating { window?.invalidateCursorRects(for: self) }
        update()
    }

    func endFloatingEditing() {
        selectTool(nil)
    }

    private func dismiss() {
        if isFloating { onFloatingToolbarDismiss?() } else { cancel() }
    }

    private func commitDraft() {
        if let draft { history.append(draft) }
        draft = nil
    }

    private func changeHistory(redo: Bool) {
        finishText()
        commitDraft()
        if redo { history.redo() } else { history.undo() }
        annotationsChanged()
    }

    private func resetAnnotations() {
        finishText(discard: true)
        draft = nil
        history = ScreenshotAnnotationHistory()
        toolbarState.tool = nil
        annotationsChanged()
    }

    private func annotationsChanged() {
        if toolbarState.canUndo != history.canUndo { toolbarState.canUndo = history.canUndo }
        if toolbarState.canRedo != history.canRedo { toolbarState.canRedo = history.canRedo }
        invalidate(selection, padding: 0)
    }

    private func beginText(at point: CGPoint, in selection: CGRect) {
        let style = toolbarState.annotationStyle
        let font = NSFont.systemFont(ofSize: style.textSize, weight: .semibold)
        let field = NSTextField()
        field.font = font
        field.placeholderString = "输入文字"
        field.textColor = style.color
        field.backgroundColor = NSColor(white: 0.1, alpha: 0.86)
        field.drawsBackground = true
        field.focusRingType = .none
        field.delegate = self
        let width = min(selection.width, 220)
        let height = ceil(font.ascender - font.descender) + 6
        let origin = CGPoint(x: min(point.x, selection.maxX - width),
                             y: max(selection.minY, min(point.y, selection.maxY - height)))
        field.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        textEditor = (field, CGPoint(x: origin.x + 3, y: origin.y + 2), style)
        addSubview(field, positioned: .below, relativeTo: isFloating ? nil : toolbar)
        window?.makeFirstResponder(field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === textEditor?.field else { return }
        finishText()
    }

    private func finishText(discard: Bool = false) {
        guard let editor = textEditor else { return }
        textEditor = nil
        let value = editor.field.currentEditor()?.string ?? editor.field.stringValue
        if !discard {
            history.append(ScreenshotAnnotation(tool: .text, style: editor.style, points: [editor.point], text: value))
        }
        if editor.field.currentEditor() != nil { window?.makeFirstResponder(self) }
        editor.field.removeFromSuperview()
        annotationsChanged()
    }

    private func selectFrontmostWindow() {
        guard let region = display.frontmostWindowRegion else { return }
        selection = region
        update()
    }

    func submit(_ action: ScreenshotTool.Action) {
        guard let selection = currentRegion, drag == nil else { return }
        finishText()
        commitDraft()
        annotationsChanged()
        finish(action, selection, annotationRenderer.capture(selection, annotations: history.visible))
    }

    private func update() {
        if isFloating {
            onFloatingToolbarLayout?()
            return
        }
        let region = currentRegion.flatMap { $0.width >= 2 && $0.height >= 2 ? $0 : nil }
        let handles = region != nil && drag == nil
        let showsSize = region != nil && selection != nil
        if region != drawnRegion || showsSize != (drawnSizeBadge != nil) {
            invalidate(drawnSizeBadge?.frame, padding: 2)
            drawnSizeBadge = showsSize ? region.map(makeSizeBadge(for:)) : nil
            invalidate(drawnSizeBadge?.frame, padding: 2)
        }
        if region != drawnRegion || handles != drawnHandles {
            if drawnRegion == nil || region == nil {
                setNeedsDisplay(display.bounds)
            } else {
                invalidate(drawnRegion, padding: 6)
                invalidate(region, padding: 6)
            }
            drawnRegion = region
            drawnHandles = handles
        }
        if let region, selection != nil, drag == nil {
            let size = toolbarState.size
            let x = max(6, min(region.maxX - size.width, display.bounds.maxX - size.width - 6))
            let below = region.maxY + 7
            let above = (drawnSizeBadge?.frame.minY ?? region.minY) - size.height - 7
            let y = below + size.height <= display.bounds.maxY - 6 ? below : max(6, above)
            toolbar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            toolbar.isHidden = false
        } else {
            toolbar.isHidden = true
        }
        invalidate(drawnLens, padding: 2)
        drawnLens = pointer.flatMap(magnifierFrame)
        invalidate(drawnLens, padding: 2)
    }

    private func invalidate(_ rect: CGRect?, padding: CGFloat) {
        if let rect { setNeedsDisplay(rect.insetBy(dx: -padding, dy: -padding)) }
    }

    private func makeSizeBadge(for region: CGRect) -> SizeBadge {
        let size = "\(Int(region.width.rounded())) × \(Int(region.height.rounded())) pt"
        let label = NSAttributedString(string: size, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.77, green: 0.86, blue: 1, alpha: 1)
        ])
        let width = ceil(label.size().width) + 14
        let height = ceil(label.size().height) + 6
        let x = max(6, min(region.minX, display.bounds.maxX - width - 6))
        let above = region.minY - height - 6
        let y = above >= 6 ? above : min(region.minY + 8, display.bounds.maxY - height - 6)
        return SizeBadge(label: label, frame: CGRect(x: x, y: y, width: width, height: height))
    }

    private func point(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, point.x), display.bounds.maxX), y: min(max(0, point.y), display.bounds.maxY))
    }

    private func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        let x = min(max(0, rect.minX + dx), max(0, display.bounds.width - rect.width))
        let y = min(max(0, rect.minY + dy), max(0, display.bounds.height - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private func handleCenter(_ handle: ScreenshotResizeHandle, in region: CGRect) -> CGPoint {
        let point = handle.position(in: region)
        let inset = handleRadius + 1
        return CGPoint(x: min(max(inset, point.x), display.bounds.maxX - inset),
                       y: min(max(inset, point.y), display.bounds.maxY - inset))
    }

    private func resizeHandle(at point: CGPoint, in region: CGRect) -> ScreenshotResizeHandle? {
        let hitRadius = handleRadius + 4
        return ScreenshotResizeHandle.all.compactMap { handle -> (ScreenshotResizeHandle, CGFloat)? in
            let center = handleCenter(handle, in: region)
            let dx = center.x - point.x
            let dy = center.y - point.y
            let distance = dx * dx + dy * dy
            return distance <= hitRadius * hitRadius ? (handle, distance) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    private func magnifierFrame(at point: CGPoint) -> CGRect? {
        guard toolbarState.tool == nil else { return nil }
        let width = CGFloat(magnifierColumns) * magnifierPixelSize
        let height = CGFloat(magnifierRows) * magnifierPixelSize
        let gap: CGFloat = 20
        let area = display.bounds.insetBy(dx: 6, dy: 6)
        let buttons = toolbar.isHidden ? .null : toolbar.frame
        guard !buttons.contains(point) else { return nil }
        for y in [point.y + gap, point.y - gap - height] {
            for x in [point.x + gap, point.x - gap - width] {
                let frame = CGRect(x: x, y: y, width: width, height: height)
                if area.contains(frame), !frame.intersects(buttons) { return frame }
            }
        }
        return nil
    }

    private func drawMagnifier(at point: CGPoint, in lens: CGRect) {
        let pixel = display.pixel(at: point)
        let source = CGRect(x: pixel.x - CGFloat(magnifierColumns / 2), y: pixel.y - CGFloat(magnifierRows / 2),
                            width: CGFloat(magnifierColumns), height: CGFloat(magnifierRows))
        let clipped = source.intersection(display.pixelBounds)
        guard let pixels = display.image.cropping(to: clipped) else { return }

        let shape = NSBezierPath(roundedRect: lens, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        let sample = NSImage(cgImage: pixels, size: clipped.size)
        let sampleFrame = CGRect(x: lens.minX + (clipped.minX - source.minX) * magnifierPixelSize,
                                 y: lens.minY + (clipped.minY - source.minY) * magnifierPixelSize,
                                 width: clipped.width * magnifierPixelSize, height: clipped.height * magnifierPixelSize)
        sample.draw(in: sampleFrame, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        magnifierAccent.withAlphaComponent(0.85).setStroke()
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: lens.minX, y: lens.midY))
        crosshair.line(to: CGPoint(x: lens.maxX, y: lens.midY))
        crosshair.move(to: CGPoint(x: lens.midX, y: lens.minY))
        crosshair.line(to: CGPoint(x: lens.midX, y: lens.maxY))
        crosshair.lineWidth = 1
        crosshair.stroke()
        let center = CGRect(x: lens.midX - magnifierPixelSize / 2, y: lens.midY - magnifierPixelSize / 2,
                            width: magnifierPixelSize, height: magnifierPixelSize)
        NSColor.black.setStroke()
        NSBezierPath(rect: center).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: center.insetBy(dx: 1, dy: 1)).stroke()
        NSGraphicsContext.restoreGraphicsState()

        magnifierAccent.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

private extension ScreenshotAnnotation.Tool {
    var label: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .polyline: "折线"
        case .arrow: "箭头"
        case .pencil: "铅笔"
        case .marker: "荧光笔"
        case .mosaic: "马赛克"
        case .blur: "高斯模糊"
        case .text: "文字"
        case .eraser: "橡皮擦"
        }
    }

    var icon: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .line: "line.diagonal"
        case .polyline: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .arrow: "arrow.up.right"
        case .pencil: "pencil"
        case .marker: "highlighter"
        case .mosaic: "checkerboard.rectangle"
        case .blur: "drop.halffull"
        case .text: "textformat"
        case .eraser: "eraser"
        }
    }

    var variants: [Self] {
        switch self {
        case .rectangle, .ellipse: [.rectangle, .ellipse]
        case .arrow, .line, .polyline: [.arrow, .line, .polyline]
        case .mosaic, .blur: [.mosaic, .blur]
        default: [self]
        }
    }
}

@MainActor
private final class ScreenshotToolbarState: ObservableObject {
    let isFloating: Bool
    @Published var tool: ScreenshotAnnotation.Tool?
    @Published var style = ScreenshotAnnotation.Style()
    @Published var canUndo = false
    @Published var canRedo = false

    init(isFloating: Bool) { self.isFloating = isFloating }

    var size: CGSize { CGSize(width: isFloating ? 375 : 404, height: tool == nil ? 33 : 65) }

    var alternate: ScreenshotAnnotation.Tool? {
        guard let tool, tool.variants.count > 1, let index = tool.variants.firstIndex(of: tool) else { return nil }
        return tool.variants[(index + 1) % tool.variants.count]
    }

    var annotationStyle: ScreenshotAnnotation.Style {
        var annotationStyle = style
        annotationStyle.usesArea = tool?.usesArea == true && style.usesArea
        return annotationStyle
    }
}

private struct ScreenshotSelectionActions: View {
    @ObservedObject var state: ScreenshotToolbarState
    let select: (ScreenshotAnnotation.Tool?) -> Void
    let changeHistory: (Bool) -> Void
    let perform: (ScreenshotTool.Action) -> Void
    let cancel: () -> Void

    private let tools: [ScreenshotAnnotation.Tool] = [.rectangle, .arrow, .pencil, .marker, .mosaic, .text, .eraser]
    private let palette: [(String, NSColor)] = [
        ("红色", ScreenshotAnnotation.Style().color), ("橙色", .systemOrange), ("黄色", .systemYellow),
        ("绿色", .systemGreen), ("蓝色", .systemBlue), ("紫色", .systemPurple), ("白色", .white), ("黑色", .black)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tools, id: \.self) { tool in
                    let active = state.tool.map { tool.variants.contains($0) } ?? false
                    let shown = active ? state.tool ?? tool : tool
                    ScreenshotToolbarButton(label: shown.label, icon: shown.icon, selected: active) {
                        select(active ? nil : tool)
                    }
                }
                divider
                ScreenshotToolbarButton(label: "撤销", icon: "arrow.uturn.backward", shortcut: "⌘Z") { changeHistory(false) }
                    .disabled(!state.canUndo)
                ScreenshotToolbarButton(label: "重做", icon: "arrow.uturn.forward", shortcut: "⇧⌘Z") { changeHistory(true) }
                    .disabled(!state.canRedo)
                divider
                ScreenshotToolbarButton(label: state.isFloating ? "隐藏工具条" : "取消截图",
                                        icon: "xmark", shortcut: "Esc", action: cancel)
                if !state.isFloating {
                    ScreenshotToolbarButton(label: "悬浮", icon: "pin", shortcut: "⌘T") { perform(.pin) }
                }
                ScreenshotToolbarButton(label: "保存", icon: "arrow.down.to.line", shortcut: "⌘S") { perform(.save) }
                ScreenshotToolbarButton(label: "复制", icon: "doc.on.doc", shortcut: "↩ / ⌘C") { perform(.copy) }
            }
            .frame(height: 33)
            if let tool = state.tool {
                options(for: tool)
                    .frame(height: 32)
                    .overlay(alignment: .top) {
                        Rectangle().fill(.black.opacity(0.1)).frame(height: 1).allowsHitTesting(false)
                    }
            }
        }
        .frame(width: state.size.width, height: state.size.height, alignment: .top)
        .background(Color(red: 0.92, green: 0.95, blue: 0.99), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var divider: some View {
        Rectangle().fill(.black.opacity(0.14)).frame(width: 1, height: 14).accessibilityHidden(true)
    }

    private func options(for tool: ScreenshotAnnotation.Tool) -> some View {
        HStack(spacing: 3) {
            if tool.variants.count > 1 {
                ForEach(tool.variants, id: \.self) { variant in
                    ScreenshotToolbarButton(label: variant.label, icon: variant.icon, selected: variant == tool) {
                        select(variant)
                    }
                }
                divider
            }
            if tool.usesArea {
                ScreenshotToolbarButton(label: "笔刷", icon: "paintbrush.pointed", selected: !state.style.usesArea) {
                    state.style.usesArea = false
                }
                ScreenshotToolbarButton(label: "矩形区域", icon: "rectangle.dashed", selected: state.style.usesArea) {
                    state.style.usesArea = true
                }
                divider
            }
            if !state.annotationStyle.usesArea {
                ForEach(0..<3) { size in
                    ScreenshotToolbarButton(label: ["小", "中", "大"][size], icon: tool == .text ? "textformat.size" : "circle.fill",
                                            selected: state.style.size == size, iconSize: CGFloat(8 + 3 * size)) {
                        state.style.size = size
                    }
                }
            }
            if tool.usesColor {
                divider
                ForEach(palette, id: \.0) { label, color in
                    Button { state.style.color = color } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 13, height: 13)
                            .overlay { Circle().strokeBorder(.black.opacity(0.18)) }
                            .padding(2)
                            .overlay { Circle().strokeBorder(.blue.opacity(state.style.color == color ? 1 : 0), lineWidth: 2) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(label)
                    .accessibilityLabel(label)
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct ScreenshotToolbarButton: View {
    let label: String
    let icon: String
    var shortcut = ""
    var selected = false
    var iconSize: CGFloat = 13
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(Color(red: 0.16, green: 0.22, blue: 0.34).opacity(isEnabled ? 1 : 0.32))
                .frame(width: 27, height: 25)
                .background(Color.blue.opacity(selected ? 0.28 : (isHovering && isEnabled ? 0.13 : 0)),
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(shortcut.isEmpty ? label : "\(label) · \(shortcut)")
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
