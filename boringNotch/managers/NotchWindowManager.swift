import Foundation

struct NotchDisplay: Equatable {
    let uuid: String
    let frame: CGRect
    let closedNotchSize: CGSize
    let menuBarHeight: CGFloat
    let hasPhysicalNotch: Bool

    var notchAnchor: CGPoint {
        CGPoint(x: frame.midX, y: frame.maxY)
    }
}

@MainActor
protocol NotchPanelWindow: AnyObject {
    func show(at notchAnchor: CGPoint, onLockScreen: Bool)
    func hide()
    func dispose()
}

@MainActor
final class NotchWindowManager {
    enum Mode {
        case allDisplays
        case singleDisplay(preferred: String?, fallback: String?)
    }

    enum Presentation {
        case desktop
        case lockScreen
        case hidden
    }

    private struct Panel {
        let viewModel: BoringViewModel
        let window: any NotchPanelWindow
    }

    private let makeWindow: @MainActor (BoringViewModel) -> any NotchPanelWindow
    private let singleViewModel = BoringViewModel()
    private var singlePanel: Panel?
    private var panelsByDisplay: [String: Panel] = [:]

    init(makeWindow: @escaping @MainActor (BoringViewModel) -> any NotchPanelWindow) {
        self.makeWindow = makeWindow
    }

    func reconcile(displays: [NotchDisplay], mode: Mode, presentation: Presentation) {
        guard presentation != .hidden else {
            removeAll()
            return
        }
        let onLockScreen = presentation == .lockScreen

        switch mode {
        case .allDisplays:
            removeSinglePanel()
            let connected = Set(displays.map(\.uuid))
            for uuid in panelsByDisplay.keys.filter({ !connected.contains($0) }) {
                removeDisplayPanel(uuid)
            }
            for display in displays {
                let panel = panelsByDisplay[display.uuid] ?? makePanel(for: display, model: BoringViewModel())
                panelsByDisplay[display.uuid] = panel
                place(panel, on: display, onLockScreen: onLockScreen)
            }

        case let .singleDisplay(preferred, fallback):
            removeDisplayPanels()
            let target = displays.first { $0.uuid == preferred } ?? displays.first { $0.uuid == fallback }
            guard let target else {
                if let panel = singlePanel, panel.viewModel.display != nil {
                    panel.viewModel.updateDisplay(nil)
                    panel.window.hide()
                }
                return
            }

            let panel = singlePanel ?? makePanel(for: target, model: singleViewModel)
            singlePanel = panel
            place(panel, on: target, onLockScreen: onLockScreen)
        }
    }

    func togglePanel(at pointer: CGPoint) {
        if let panel = singlePanel, panel.viewModel.display != nil {
            panel.viewModel.toggleFromShortcut()
        } else {
            panelsByDisplay.values.first { $0.viewModel.display?.frame.contains(pointer) == true }?
                .viewModel.toggleFromShortcut()
        }
    }

    func removeAll() {
        removeSinglePanel()
        removeDisplayPanels()
    }

    private func makePanel(for display: NotchDisplay, model: BoringViewModel) -> Panel {
        model.updateDisplay(display)
        return Panel(viewModel: model, window: makeWindow(model))
    }

    private func place(_ panel: Panel, on display: NotchDisplay, onLockScreen: Bool) {
        panel.viewModel.updateDisplay(display)
        panel.window.show(at: display.notchAnchor, onLockScreen: onLockScreen)
    }

    private func removeSinglePanel() {
        guard let panel = singlePanel else { return }
        singlePanel = nil
        panel.viewModel.updateDisplay(nil)
        panel.window.dispose()
    }

    private func removeDisplayPanels() {
        for uuid in Array(panelsByDisplay.keys) {
            removeDisplayPanel(uuid)
        }
    }

    private func removeDisplayPanel(_ uuid: String) {
        guard let panel = panelsByDisplay.removeValue(forKey: uuid) else { return }
        panel.viewModel.destroy()
        panel.window.dispose()
    }
}
