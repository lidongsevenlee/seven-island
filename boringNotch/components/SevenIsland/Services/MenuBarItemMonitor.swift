import AppKit
import ApplicationServices
import Combine
import Darwin
import Foundation

@MainActor
final class MenuBarItemMonitor: ObservableObject {
    static let shared = MenuBarItemMonitor()

    @Published private(set) var items: [MenuBarProxyItem] = []
    @Published private(set) var isAuthorized: Bool = AXIsProcessTrusted()
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastUpdated: Date?

    private var timer: Timer?
    private var currentScreenUUID: String?
    private var refreshGeneration = 0
    private var refreshSuspendedUntil: Date?
    private var refreshStartedAt: Date?
    private var settingsRefreshTask: Task<Void, Never>?
    private var settingsWatcher: MenuBarSettingsPreferenceWatcher?

    private let pollInterval: TimeInterval = 5.0
    private let refreshStaleInterval: TimeInterval = 2.5
    private let workerQueue = DispatchQueue(label: "com.local.seven-island.menubar-monitor", qos: .utility)

    private init() {}

    func start(screenUUID: String?) {
        currentScreenUUID = screenUUID
        setupSettingsWatcherIfNeeded()
        refresh(screenUUID: screenUUID)
        guard timer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(screenUUID: self.currentScreenUUID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func updateScreen(_ screenUUID: String?) {
        currentScreenUUID = screenUUID
        refresh(screenUUID: screenUUID)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
        settingsWatcher = nil
    }

    func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refreshAuthorizationState()
    }

    func refresh(screenUUID: String?) {
        currentScreenUUID = screenUUID
        refreshAuthorizationState()

        if let refreshSuspendedUntil, refreshSuspendedUntil > Date() {
            return
        }

        guard isAuthorized else {
            items = []
            lastUpdated = Date()
            return
        }

        if isRefreshing {
            if let refreshStartedAt, Date().timeIntervalSince(refreshStartedAt) > refreshStaleInterval {
                refreshGeneration += 1
                isRefreshing = false
            } else {
                return
            }
        }

        guard let context = collectionContext(screenUUID: screenUUID) else {
            items = []
            lastUpdated = Date()
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        refreshStartedAt = Date()

        workerQueue.async { [weak self] in
            let collected = MenuBarAXCollector.collect(context: context)

            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.refreshGeneration else { return }

                self.items = collected
                self.lastUpdated = Date()
                self.isRefreshing = false
                self.refreshStartedAt = nil
            }
        }
    }

    func suspendRefreshForMenuInteraction() {
        refreshSuspendedUntil = Date().addingTimeInterval(5)
        refreshGeneration += 1
        isRefreshing = false
        refreshStartedAt = nil
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
        stop()
    }

    func press(_ item: MenuBarProxyItem, at screenPoint: CGPoint = NSEvent.mouseLocation) {
        if item.isCurrentApplication {
            SevenIslandStatusMenuPresenter.showMenu(at: screenPoint)
            return
        }

        let element = item.element
        let processIdentifier = item.processIdentifier
        let displayBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        workerQueue.async {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
            MenuBarPanelPositioner.moveMenuPanel(
                for: processIdentifier,
                near: screenPoint,
                displayBounds: displayBounds
            )
        }
    }

    private func refreshAuthorizationState() {
        isAuthorized = AXIsProcessTrusted()
    }

    private func setupSettingsWatcherIfNeeded() {
        guard settingsWatcher == nil else { return }

        settingsWatcher = MenuBarSettingsPreferenceWatcher { [weak self] in
            Task { @MainActor in
                self?.scheduleSettingsRefresh()
            }
        }
    }

    private func scheduleSettingsRefresh() {
        guard isAuthorized else {
            refreshAuthorizationState()
            return
        }

        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            refresh(screenUUID: currentScreenUUID)
        }
    }

    private func collectionContext(screenUUID: String?) -> MenuBarCollectionContext? {
        let selectedScreen: NSScreen?
        if let screenUUID {
            selectedScreen = NSScreen.screen(withUUID: screenUUID)
        } else {
            selectedScreen = NSScreen.main
        }

        guard let screen = selectedScreen else { return nil }

        let size = getClosedNotchSize(screenUUID: screenUUID)
        let notchRect = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        let displayBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, notchRect.height, 22)
        let topBand = CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - menuBarHeight - 8,
            width: screen.frame.width,
            height: menuBarHeight + 16
        )

        let apps = NSWorkspace.shared.runningApplications
            .filter { app in
                !app.isTerminated
            }
            .map {
                MenuBarCandidateApplication(
                    processIdentifier: $0.processIdentifier,
                    localizedName: $0.localizedName,
                    bundleIdentifier: $0.bundleIdentifier,
                    icon: $0.icon,
                    activationPolicy: $0.activationPolicy
                )
            }

        return MenuBarCollectionContext(
            screenFrame: screen.frame,
            notchRect: notchRect,
            topBand: topBand,
            displayBounds: displayBounds,
            applications: apps
        )
    }
}

private enum MenuBarPanelPositioner {
    private static let maxTraversalDepth = 4

    static func moveMenuPanel(
        for processIdentifier: pid_t,
        near screenPoint: CGPoint,
        displayBounds: CGRect
    ) {
        guard !displayBounds.isNull else { return }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.12)

        for delay in [40_000, 90_000, 160_000] {
            usleep(useconds_t(delay))
            if moveFirstMenuPanel(in: appElement, near: screenPoint, displayBounds: displayBounds) {
                return
            }
        }
    }

    private static func moveFirstMenuPanel(
        in appElement: AXUIElement,
        near screenPoint: CGPoint,
        displayBounds: CGRect
    ) -> Bool {
        var seen = Set<UInt>()

        for candidate in menuPanelCandidates(in: appElement) {
            let key = CFHash(candidate)
            guard seen.insert(UInt(key)).inserted else { continue }
            guard isMenuPanel(candidate),
                  let size = sizeAttribute(candidate, kAXSizeAttribute as CFString),
                  isPlausibleMenuPanelSize(size) else {
                continue
            }

            let target = targetAXPosition(
                near: screenPoint,
                panelSize: size,
                displayBounds: displayBounds
            )

            if setPosition(target, for: candidate) {
                return true
            }
        }

        return false
    }

    private static func menuPanelCandidates(in appElement: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []

        if let focusedElement = axElementAttribute(appElement, kAXFocusedUIElementAttribute as CFString) {
            candidates.append(focusedElement)
            candidates.append(contentsOf: parentChain(from: focusedElement))
            candidates.append(contentsOf: descendants(from: focusedElement, depth: 0))
        }

        if let focusedWindow = axElementAttribute(appElement, kAXFocusedWindowAttribute as CFString) {
            candidates.append(focusedWindow)
            candidates.append(contentsOf: descendants(from: focusedWindow, depth: 0))
        }

        for window in axElementArrayAttribute(appElement, kAXWindowsAttribute as CFString) {
            candidates.append(window)
            candidates.append(contentsOf: descendants(from: window, depth: 0))
        }

        return candidates
    }

    private static func descendants(from element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < maxTraversalDepth else { return [] }

        var result: [AXUIElement] = []
        for child in axElementArrayAttribute(element, kAXChildrenAttribute as CFString) {
            result.append(child)
            result.append(contentsOf: descendants(from: child, depth: depth + 1))
        }
        return result
    }

    private static func parentChain(from element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var current = element

        for _ in 0..<maxTraversalDepth {
            guard let parent = axElementAttribute(current, kAXParentAttribute as CFString) else {
                break
            }
            result.append(parent)
            current = parent
        }

        return result
    }

    private static func isMenuPanel(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        let combined = "\(role) \(subrole)"

        return combined.contains("Menu")
            || combined.contains("Popover")
            || combined.contains("Dialog")
    }

    private static func isPlausibleMenuPanelSize(_ size: CGSize) -> Bool {
        size.width >= 40
            && size.height >= 20
            && size.width <= 720
            && size.height <= 900
    }

    private static func targetAXPosition(
        near screenPoint: CGPoint,
        panelSize: CGSize,
        displayBounds: CGRect
    ) -> CGPoint {
        let x = min(
            max(screenPoint.x, displayBounds.minX),
            displayBounds.maxX - panelSize.width
        )
        let topY = min(
            max(screenPoint.y, displayBounds.minY + panelSize.height),
            displayBounds.maxY
        )

        return CGPoint(
            x: x,
            y: displayBounds.minY + displayBounds.maxY - topY
        )
    }

    private static func setPosition(_ point: CGPoint, for element: AXUIElement) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            value
        ) == .success
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((axValue as! AXValue), .cgSize, &size) else { return nil }
        return size
    }

    private static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (axValue as! AXUIElement)
    }

    private static func axElementArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let values = value as? [AXUIElement] else {
            return []
        }
        return values
    }
}

private struct MenuBarCollectionContext {
    let screenFrame: CGRect
    let notchRect: CGRect
    let topBand: CGRect
    let displayBounds: CGRect
    let applications: [MenuBarCandidateApplication]
}

private struct MenuBarCandidateApplication {
    let processIdentifier: pid_t
    let localizedName: String?
    let bundleIdentifier: String?
    let icon: NSImage?
    let activationPolicy: NSApplication.ActivationPolicy
}

private final class MenuBarSettingsPreferenceWatcher {
    private let queue = DispatchQueue(label: "com.local.seven-island.menubar-settings-watcher", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var preferenceTimer: DispatchSourceTimer?
    private var lastPreferenceSignature: String?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        start()
    }

    deinit {
        sources.forEach { $0.cancel() }
        preferenceTimer?.cancel()
    }

    private func start() {
        let fileManager = FileManager.default
        guard let preferencesURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true) else {
            return
        }

        let preferenceFiles = [
            "com.apple.controlcenter.plist",
            "com.apple.systemuiserver.plist"
        ]

        watch(preferencesURL)
        for file in preferenceFiles {
            watch(preferencesURL.appendingPathComponent(file))
        }

        startPreferenceValueWatcher()
    }

    private func watch(_ url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.onChange()
            }
        }

        source.setCancelHandler {
            close(descriptor)
        }

        source.resume()
        sources.append(source)
    }

    private func startPreferenceValueWatcher() {
        lastPreferenceSignature = menuBarPreferenceSignature()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let signature = self.menuBarPreferenceSignature()
            guard signature != self.lastPreferenceSignature else { return }

            self.lastPreferenceSignature = signature
            Task { @MainActor in
                self.onChange()
            }
        }

        timer.resume()
        preferenceTimer = timer
    }

    private func menuBarPreferenceSignature() -> String {
        let domains = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver"
        ]
        let hosts = [
            kCFPreferencesAnyHost,
            kCFPreferencesCurrentHost
        ]
        let interestingKeyPrefixes = [
            "NSStatusItem Visible",
            "NSStatusItem VisibleCC",
            "NSStatusItem Preferred Position"
        ]
        let interestingKeys = Set(["menuExtras"])

        var parts: [String] = []

        for domain in domains {
            let appID = domain as CFString
            CFPreferencesAppSynchronize(appID)

            for host in hosts {
                guard let keys = CFPreferencesCopyKeyList(
                    appID,
                    kCFPreferencesCurrentUser,
                    host
                ) as? [String] else {
                    continue
                }

                for key in keys.sorted() {
                    guard interestingKeys.contains(key)
                        || interestingKeyPrefixes.contains(where: { key.hasPrefix($0) }) else {
                        continue
                    }

                    let value = CFPreferencesCopyValue(
                        key as CFString,
                        appID,
                        kCFPreferencesCurrentUser,
                        host
                    )
                    parts.append("\(domain)|\(host)|\(key)=\(String(describing: value))")
                }
            }
        }

        return parts.joined(separator: "\n")
    }
}

private enum MenuBarAXCollector {
    private static let maxTraversalDepth = 10

    static func collect(context: MenuBarCollectionContext) -> [MenuBarProxyItem] {
        var results: [MenuBarProxyItem] = []
        var seen = Set<String>()

        for app in orderedApplications(context.applications) {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.12)

            for root in menuBarRoots(in: appElement, app: app) {
                for element in menuBarDescendants(from: root, depth: 0) {
                    guard let frame = frame(of: element), hasMenuBarItemSize(frame) else {
                        continue
                    }

                    guard isCovered(
                        frame,
                        notchRect: context.notchRect,
                        screenFrame: context.screenFrame,
                        topBand: context.topBand,
                        displayBounds: context.displayBounds
                    ) else {
                        continue
                    }

                    guard looksLikeMenuBarItem(element, frame: frame) else {
                        continue
                    }

                    let title = displayTitle(for: element, fallback: app.localizedName ?? "菜单栏项目")
                    let id = id(for: app, frame: frame)
                    guard seen.insert(id).inserted else { continue }

                    let itemImage = imageAttribute(for: element)

                    // Resolve actual owning app for items found under systemuiserver.
                    let resolvedApp: MenuBarCandidateApplication
                    if app.bundleIdentifier == "com.apple.systemuiserver" {
                        resolvedApp = resolveOwningApp(for: element, title: title, applications: context.applications) ?? app
                    } else {
                        resolvedApp = app
                    }

                    // For unresolved third-party items, capture icon from screen.
                    // Electron tray icons don't expose AXImage/AXIcon, and title
                    // matching may fail, but the visible icon is on screen.
                    var resolvedImage = itemImage
                    if resolvedApp.bundleIdentifier == "com.apple.systemuiserver" {
                        if itemImage == nil {
                            // Skip screen capture for known native items (clock, wifi,
                            // battery, etc.) — they should keep the SF Symbol path.
                            let fallbackName = fallbackSystemImageName(for: title)
                            if fallbackName == "circle.grid.2x2.fill" {
                                let captureRect = captureFrame(for: frame, topBand: context.topBand, displayBounds: context.displayBounds)
                                resolvedImage = menuBarImage(in: captureRect)
                            }
                        }
                    }

                    results.append(
                        MenuBarProxyItem(
                            id: id,
                            title: title,
                            detail: resolvedApp.localizedName ?? "SystemUIServer",
                            appIcon: resolvedApp.icon,
                            menuBarImage: resolvedImage,
                            fallbackSystemImageName: fallbackSystemImageName(for: title),
                            frame: frame,
                            element: element,
                            processIdentifier: resolvedApp.processIdentifier,
                            bundleIdentifier: resolvedApp.bundleIdentifier
                        )
                    )
                }
            }
        }

        return results.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func orderedApplications(_ applications: [MenuBarCandidateApplication]) -> [MenuBarCandidateApplication] {
        let systemUIServer = applications.filter { $0.bundleIdentifier == "com.apple.systemuiserver" }
        let others = applications.filter { $0.bundleIdentifier != "com.apple.systemuiserver" }
        return systemUIServer + others
    }

    /// Try to find the actual owning application for a menu bar item found
    /// under systemuiserver's AX tree. Resolves bundleID from AXIdentifier
    /// attribute, then falls back to matching title vs app name.
    private static func resolveOwningApp(
        for element: AXUIElement,
        title: String,
        applications: [MenuBarCandidateApplication]
    ) -> MenuBarCandidateApplication? {
        // 1. AXIdentifier — NSStatusItem may expose bundle ID here
        if let identifier = stringAttribute(element, "AXIdentifier" as CFString) {
            for app in applications where app.bundleIdentifier == identifier {
                return app
            }
        }

        // 2. Title match — tray tooltip (AXDescription) often equals app name
        if !title.isEmpty {
            let lowerTitle = title.lowercased()
            for app in applications {
                guard let name = app.localizedName?.lowercased() else { continue }
                if name == lowerTitle || lowerTitle.contains(name) || name.contains(lowerTitle) {
                    return app
                }
            }
        }

        return nil
    }

    private static func isCovered(
        _ itemFrame: CGRect,
        notchRect: CGRect,
        screenFrame: CGRect,
        topBand: CGRect,
        displayBounds: CGRect
    ) -> Bool {
        guard itemFrame.width > 2, itemFrame.height > 2 else { return false }
        guard itemFrame.maxX >= screenFrame.minX, itemFrame.minX <= screenFrame.maxX else { return false }
        guard itemFrame.maxX >= notchRect.minX, itemFrame.minX <= notchRect.maxX else { return false }

        let topOriginMenuBandHeight = max(topBand.height, 64)
        if itemFrame.minY >= 0, itemFrame.maxY <= topOriginMenuBandHeight {
            return true
        }

        if itemFrame.intersects(topBand) {
            return true
        }

        let flippedFrame = flipY(itemFrame, in: displayBounds)
        return flippedFrame.intersects(topBand)
    }

    private static func captureFrame(
        for itemFrame: CGRect,
        topBand: CGRect,
        displayBounds: CGRect
    ) -> CGRect {
        if itemFrame.intersects(topBand) {
            return flipY(itemFrame, in: displayBounds).insetBy(dx: -4, dy: -4)
        }

        return itemFrame.insetBy(dx: -4, dy: -4)
    }

    private static func flipY(_ rect: CGRect, in displayBounds: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: displayBounds.minY + displayBounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func menuBarImage(in rect: CGRect) -> NSImage? {
        guard rect.width > 2, rect.height > 2 else { return nil }

        let windowID = topSevenIslandWindowID(intersecting: rect)
        let options: CGWindowListOption = windowID == kCGNullWindowID
            ? .optionOnScreenOnly
            : .optionOnScreenBelowWindow

        guard let image = CGWindowListCreateImage(
            rect,
            options,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }

        return NSImage(cgImage: image, size: rect.size)
    }

    private static func hasVisibleMenuBarContent(_ image: NSImage?) -> Bool {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return false }

        let xRange = 0..<width
        let yRange = 0..<height
        let totalPixels = width * height
        let backgroundColor = estimatedBackgroundColor(in: bitmap)
        var visiblePixels = 0

        for y in yRange {
            for x in xRange {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }

                let alpha = color.alphaComponent
                let distance = colorDistance(color, backgroundColor)

                if alpha > 0.2, distance > 0.16 {
                    visiblePixels += 1
                }
            }
        }

        return visiblePixels >= max(10, totalPixels / 100)
    }

    private static func estimatedBackgroundColor(in bitmap: NSBitmapImageRep) -> NSColor {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var count: CGFloat = 0

        func addColor(at x: Int, _ y: Int) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return }
            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
            alpha += color.alphaComponent
            count += 1
        }

        for x in 0..<width {
            addColor(at: x, 0)
            addColor(at: x, height - 1)
        }

        for y in 1..<max(1, height - 1) {
            addColor(at: 0, y)
            addColor(at: width - 1, y)
        }

        guard count > 0 else { return .black }
        return NSColor(
            calibratedRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: alpha / count
        )
    }

    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard let lhs = lhs.usingColorSpace(.deviceRGB),
              let rhs = rhs.usingColorSpace(.deviceRGB) else {
            return 0
        }

        let red = lhs.redComponent - rhs.redComponent
        let green = lhs.greenComponent - rhs.greenComponent
        let blue = lhs.blueComponent - rhs.blueComponent
        return sqrt(red * red + green * green + blue * blue)
    }

    private static func topSevenIslandWindowID(intersecting rect: CGRect) -> CGWindowID {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return kCGNullWindowID
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            let bounds = CGRect(
                x: boundsDictionary["X"] ?? 0,
                y: boundsDictionary["Y"] ?? 0,
                width: boundsDictionary["Width"] ?? 0,
                height: boundsDictionary["Height"] ?? 0
            )

            if bounds.intersects(rect) {
                return windowID
            }
        }

        return kCGNullWindowID
    }

    private static func menuBarRoots(in appElement: AXUIElement, app: MenuBarCandidateApplication) -> [AXUIElement] {
        let attributeNames = [
            "AXExtrasMenuBar" as CFString,
            kAXMenuBarAttribute as CFString
        ]

        var roots = attributeNames.compactMap { attributeName in
            axElementAttribute(appElement, attributeName)
        }

        if app.activationPolicy != .regular || app.bundleIdentifier?.lowercased().contains("clash") == true {
            roots.append(appElement)
        }

        return roots
    }

    private static func menuBarDescendants(from element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < maxTraversalDepth else { return [] }

        let children = axElementArrayAttribute(element, kAXChildrenAttribute as CFString)
        var descendants: [AXUIElement] = []

        for child in children {
            descendants.append(child)
            descendants.append(contentsOf: menuBarDescendants(from: child, depth: depth + 1))
        }

        return descendants
    }

    private static func hasMenuBarItemSize(_ frame: CGRect) -> Bool {
        frame.width >= 3
            && frame.height >= 3
            && frame.width <= 240
            && frame.height <= 46
    }

    private static func looksLikeMenuBarItem(_ element: AXUIElement, frame: CGRect) -> Bool {
        guard hasMenuBarItemSize(frame) else { return false }

        // Skip elements hidden from accessibility (e.g. Snipaste's status item
        // when "hide tray icon" is enabled — the NSStatusItem AX element remains
        // in the tree but is marked as hidden).
        if isHiddenAXElement(element) {
            return false
        }

        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        let combined = "\(role) \(subrole)"

        return combined.contains("MenuBarItem")
            || combined.contains("MenuExtra")
            || combined.contains("StatusItem")
            || combined.contains("Button")
            || combined.contains("Image")
            || combined.contains("Group")
    }

    /// Check whether the element or any of its ancestors has `AXHidden = true`.
    /// Used to filter out status items that the owning app has hidden from the
    /// menu bar (e.g. Snipaste's "hide tray icon" setting).
    private static func isHiddenAXElement(_ element: AXUIElement) -> Bool {
        if boolAttribute(element, kAXHiddenAttribute as CFString) == true {
            return true
        }
        // Walk up the parent chain
        var current = element
        for _ in 0..<4 {
            guard let parent = axElementAttribute(current, kAXParentAttribute as CFString) else {
                break
            }
            if boolAttribute(parent, kAXHiddenAttribute as CFString) == true {
                return true
            }
            current = parent
        }
        return false
    }

    private static func displayTitle(for element: AXUIElement, fallback: String) -> String {
        let candidates = [
            stringAttribute(element, kAXTitleAttribute as CFString),
            stringAttribute(element, kAXDescriptionAttribute as CFString),
            stringAttribute(element, kAXHelpAttribute as CFString),
            stringAttribute(element, kAXValueAttribute as CFString)
        ]

        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }

        return fallback
    }

    private static func fallbackSystemImageName(for title: String) -> String {
        let normalized = title.lowercased()

        if normalized.contains("wi-fi") || normalized.contains("wifi") || normalized.contains("无线") {
            return "wifi"
        }
        if normalized.contains("battery") || normalized.contains("电池") || normalized.contains("charging") {
            return "battery.100percent"
        }
        if normalized.contains("control") || normalized.contains("控制中心") {
            return "switch.2"
        }
        if normalized.contains("clock") || normalized.contains("time") || normalized.contains("时间") || normalized.contains("日期") {
            return "clock"
        }
        if normalized.contains("bluetooth") || normalized.contains("蓝牙") {
            return "dot.radiowaves.left.and.right"
        }
        if normalized.contains("sound") || normalized.contains("volume") || normalized.contains("音量") {
            return "speaker.wave.2.fill"
        }
        if normalized.contains("display") || normalized.contains("screen") || normalized.contains("显示") {
            return "display"
        }
        if normalized.contains("search") || normalized.contains("spotlight") || normalized.contains("搜索") {
            return "magnifyingglass"
        }
        if normalized.contains("siri") {
            return "sparkle"
        }
        if normalized.contains("keyboard") || normalized.contains("输入") {
            return "keyboard"
        }
        if normalized.contains("vpn") {
            return "lock.shield"
        }

        return "circle.grid.2x2.fill"
    }

    private static func id(for app: MenuBarCandidateApplication, frame: CGRect) -> String {
        [
            String(app.processIdentifier),
            String(Int(frame.minX.rounded())),
            String(Int(frame.minY.rounded())),
            String(Int(frame.width.rounded())),
            String(Int(frame.height.rounded()))
        ].joined(separator: "-")
    }

    private static func imageAttribute(for element: AXUIElement) -> NSImage? {
        let attributes = [
            "AXImage" as CFString,
            "AXIcon" as CFString
        ]

        for attribute in attributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
                  let value else {
                continue
            }

            if CFGetTypeID(value) == AXValueGetTypeID() {
                continue
            }

            if let image = value as? NSImage {
                return image
            }

            if let data = value as? Data, let image = NSImage(data: data) {
                return image
            }
        }

        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let point = pointAttribute(element, kAXPositionAttribute as CFString),
              let size = sizeAttribute(element, kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        // AXHidden values are CFBoolean; CFBoolean bridges as NSNumber in Swift
        if let number = value as? NSNumber {
            return number.boolValue
        }
        // Also check raw CFBoolean via CFBooleanGetValue
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue((axValue as! AXValue), .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((axValue as! AXValue), .cgSize, &size) else { return nil }
        return size
    }

    private static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (axValue as! AXUIElement)
    }

    private static func axElementArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let values = value as? [AXUIElement] else {
            return []
        }
        return values
    }
}
