import AppKit
import ScreenCaptureKit
@testable import Seven_Island

@main
@MainActor
enum PinnedScreenshotCaptureTests {
    static func main() async throws {
        guard #available(macOS 14.4, *), let screen = NSScreen.main else {
            print("PinnedScreenshotCaptureTests requires a display and macOS 14.4 or later")
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let tool = ScreenshotTool()
        let center = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let redPoint = CGPoint(x: center.x - 90, y: center.y)
        let bluePoint = CGPoint(x: center.x + 90, y: center.y)
        tool.pin(screenshot(color: .red), near: redPoint)
        tool.pin(screenshot(color: .blue), near: bluePoint)
        let pins = NSApp.windows.compactMap { $0 as? FloatingScreenshotPanel }
        defer { pins.forEach { $0.close() } }
        expect(pins.count == 2 && pins.allSatisfy(\.isVisible), "both screenshots must already be pinned")

        let pin = pins[0]
        let closingIDs = Set(pin.captureWindowIDs)
        let toolbarItem = pin.contentView!.menu!.items.first { $0.title == "显示工具条" }!
        expect(NSApp.sendAction(toolbarItem.action!, to: pin, from: toolbarItem), "the editing toolbar can open")
        let toolbar = pin.childWindows!.first { !closingIDs.contains(CGWindowID($0.windowNumber)) }!
        try await Task.sleep(for: .milliseconds(150))

        let content = try await SCShareableContent.currentProcess
        let pinnedIDs = Set(pins.flatMap(\.captureWindowIDs))
        expect(pinnedIDs.count == 4, "each pin has one image and one shadow window")
        let toolbarID = CGWindowID(toolbar.windowNumber)
        let onScreenIDs = Set(content.windows.map(\.windowID))
        expect(onScreenIDs.isSuperset(of: pinnedIDs.union([toolbarID])), "the capture engine sees both pins, their shadows and the toolbar")
        let exclusions = tool.windowsExcludedFromCapture(in: content.windows, notchPanelIDs: [], settingsWindowID: nil)
        let excludedIDs = Set(exclusions.map(\.windowID))
        expect(excludedIDs.isDisjoint(with: pinnedIDs), "a second screenshot includes both pinned images and their shadows")
        expect(excludedIDs.contains(toolbarID), "the active editing toolbar is excluded from the display capture")

        let withoutPins = content.windows.filter { !pinnedIDs.contains($0.windowID) }
        let partialExclusions = tool.windowsExcludedFromCapture(in: withoutPins, notchPanelIDs: [], settingsWindowID: nil)
        expect(Set(partialExclusions.map(\.windowID)) == excludedIDs,
               "an incomplete list of shareable windows preserves the same capture exclusions")

        pin.close()
        let remaining = tool.windowsExcludedFromCapture(in: content.windows, notchPanelIDs: [], settingsWindowID: nil)
        expect(Set(remaining.map(\.windowID)) == excludedIDs.union(closingIDs),
               "closing a pin removes its image and shadow from the next capture")
        print("PinnedScreenshotCaptureTests passed")
    }

    private static func screenshot(color: NSColor) -> CapturedScreenshot {
        let context = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        return CapturedScreenshot(image: context.makeImage()!, size: CGSize(width: 60, height: 40))!
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAIL: \(message)")
            exit(1)
        }
    }
}
