//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    static let captureScreenshot = Self("captureScreenshot", default: .init(.f1))
    static let panelActions: [Self] = [.captureScreenshot, .toggleNotchOpen, .toggleSneakPeek]

    static let toggleMusicTab = tab(.toggleMusicTab)
    static let toggleClipboardTab = tab(.toggleClipboardTab)
    static let toggleVSCodeTab = tab(.toggleVSCodeTab)
    static let toggleMemoTab = tab(.toggleMemoTab)
    static let toggleTodoTab = tab(.toggleTodoTab)
    static let toggleAppLauncherTab = tab(.toggleAppLauncherTab)
    static let toggleToolboxTab = tab(.toggleToolboxTab)

    private enum Tab: String, CaseIterable {
        case toggleMusicTab
        case toggleClipboardTab = "clipboardHistoryPanel"
        case toggleVSCodeTab
        case toggleMemoTab
        case toggleTodoTab
        case toggleAppLauncherTab
        case toggleToolboxTab

        var key: KeyboardShortcuts.Key {
            switch self {
            case .toggleMusicTab: .one
            case .toggleClipboardTab: .two
            case .toggleVSCodeTab: .three
            case .toggleMemoTab: .four
            case .toggleTodoTab: .five
            case .toggleAppLauncherTab: .six
            case .toggleToolboxTab: .seven
            }
        }

        var previousKey: KeyboardShortcuts.Key {
            switch self {
            case .toggleTodoTab: .seven
            case .toggleAppLauncherTab: .five
            case .toggleToolboxTab: .six
            default: key
            }
        }

        var preset: Shortcut { Shortcut(key, modifiers: [.command]) }
    }

    private static func tab(_ tab: Tab) -> Self {
        _ = migrateTabShortcutPresets
        let otherTabs = Tab.allCases.filter { $0 != tab }.map { Self($0.rawValue) }
        let isTaken = (panelActions + otherTabs).contains { $0.shortcut == tab.preset }
        return Self(tab.rawValue, default: isTaken ? nil : tab.preset)
    }

    private static let migrateTabShortcutPresets: Void = {
        let defaults = UserDefaults.standard
        let migrationKey = "sevenIslandMigratedTabShortcutOrder"
        guard !defaults.bool(forKey: migrationKey) else { return }

        let migrateControlCommand = !defaults.bool(forKey: "sevenIslandMigratedCommandTabShortcuts")
        var reserved = Set(panelActions.compactMap(\.shortcut))
        var moves: [(name: Self, current: Shortcut, next: Shortcut)] = []

        for tab in Tab.allCases {
            let name = Self(tab.rawValue)
            guard let current = name.shortcut else { continue }
            let previous = Shortcut(tab.previousKey, modifiers: [.command])
            let legacy = Shortcut(tab.previousKey, modifiers: [.control, .command])
            let changesOrder = current == previous && current != tab.preset
            let removesControl = migrateControlCommand && tab != .toggleTodoTab && current == legacy
            if changesOrder || removesControl {
                moves.append((name, current, tab.preset))
            } else {
                reserved.insert(current)
            }
        }

        while let blocked = moves.firstIndex(where: { reserved.contains($0.next) }) {
            reserved.insert(moves.remove(at: blocked).current)
        }
        for move in moves {
            move.name.shortcut = move.next
        }

        defaults.set(true, forKey: migrationKey)
    }()
}
