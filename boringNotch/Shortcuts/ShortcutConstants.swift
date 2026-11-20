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

    static let toggleMusicTab = tab(.toggleMusicTab, key: .one)
    static let toggleClipboardTab = tab(.toggleClipboardTab, key: .two)
    static let toggleVSCodeTab = tab(.toggleVSCodeTab, key: .three)
    static let toggleMemoTab = tab(.toggleMemoTab, key: .four)
    static let toggleAppLauncherTab = tab(.toggleAppLauncherTab, key: .five)
    static let toggleToolboxTab = tab(.toggleToolboxTab, key: .six)

    private enum Tab: String, CaseIterable {
        case toggleMusicTab
        case toggleClipboardTab = "clipboardHistoryPanel"
        case toggleVSCodeTab
        case toggleMemoTab
        case toggleAppLauncherTab
        case toggleToolboxTab
    }

    private static func tab(_ tab: Tab, key: KeyboardShortcuts.Key) -> Self {
        let preset = Shortcut(key, modifiers: [.command])
        let otherTabs = Tab.allCases.filter { $0 != tab }.map { Self($0.rawValue) }
        let isTaken = (panelActions + otherTabs).contains { $0.shortcut == preset }
        return Self(tab.rawValue, default: isTaken ? nil : preset)
    }

    static func migrateTabShortcutPresets(_ names: [Self]) {
        let migrationKey = "sevenIslandMigratedCommandTabShortcuts"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        for name in names {
            guard let preset = name.defaultShortcut, let key = preset.key,
                  name.shortcut == Shortcut(key, modifiers: [.control, .command]) else { continue }
            name.shortcut = preset
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }
}
