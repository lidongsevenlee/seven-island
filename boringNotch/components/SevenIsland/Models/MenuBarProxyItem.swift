import AppKit
import ApplicationServices
import Foundation

struct MenuBarProxyItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let appIcon: NSImage?
    let menuBarImage: NSImage?
    let fallbackSystemImageName: String
    let frame: CGRect
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String?

    var isCurrentApplication: Bool {
        processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}
