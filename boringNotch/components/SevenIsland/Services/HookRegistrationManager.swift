//
//  HookRegistrationManager.swift
//  boringNotch
//
//  Installs/uninstalls Seven Island hook entries in ~/.claude/settings.json
//  and ~/.codex/hooks.json. The hook script lives inside the app bundle and
//  is referenced by absolute path — it is never copied to ~/.claude/hooks/.
//

import Foundation

enum AgentPlatform: String {
    case claude, codex, opencode

    var displayName: String {
        switch self {
        case .claude:   return "Claude Code"
        case .codex:    return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    /// SF Symbol used as a generic per-platform glyph (used by HooksActivityView).
    var iconName: String {
        switch self {
        case .claude:   return "sparkles"
        case .codex:    return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal"
        }
    }

    /// App-side brand accent color (RGB) — used by HooksActivityView.
    var brandColorRGB: (Double, Double, Double) {
        switch self {
        case .claude:   return (0.85, 0.55, 0.35)
        case .codex:    return (0.35, 0.70, 0.95)
        case .opencode: return (0.55, 0.85, 0.55)
        }
    }
}

final class HookRegistrationManager {
    static let shared = HookRegistrationManager()

    // MARK: - Paths

    /// Absolute path to the bundled hook script (varies with app install location).
    static var bundledScriptPath: String {
        Bundle.main.url(forResource: "seven-island-hook", withExtension: "sh")?.path ?? ""
    }

    /// Absolute path to the bundled OpenCode JS plugin (varies with app install location).
    static var bundledOpenCodePluginPath: String {
        Bundle.main.url(forResource: "seven-island-opencode", withExtension: "js")?.path ?? ""
    }

    /// Settings file holding the `hooks` section for each platform.
    static func settingsPath(_ platform: AgentPlatform) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch platform {
        case .claude:    return home + "/.claude/settings.json"
        case .codex:     return home + "/.codex/hooks.json"
        case .opencode:  return home + "/.config/opencode/config.json"
        }
    }

    /// Installed plugin path (where we copy the bundled JS to).
    static var installedOpenCodePluginPath: String {
        NSHomeDirectory() + "/.config/opencode/plugins/seven-island-opencode.js"
    }

    // MARK: - Installation status

    /// True when our hook entries (or OpenCode plugin) are present.
    static func isRegistered(_ platform: AgentPlatform) -> Bool {
        switch platform {
        case .claude, .codex:
            let scriptPath = bundledScriptPath
            guard !scriptPath.isEmpty else { return false }
            guard let settings = readSettings(platform),
                  let hooks = settings["hooks"] as? [String: Any] else { return false }
            for (_, value) in hooks {
                guard let entries = value as? [[String: Any]] else { continue }
                for entry in entries {
                    if let hookList = entry["hooks"] as? [[String: Any]] {
                        for h in hookList {
                            if let cmd = h["command"] as? String, cmd.contains(scriptPath) {
                                return true
                            }
                        }
                    }
                }
            }
            return false
        case .opencode:
            // 1) plugin file installed; 2) config.json plugin array mentions our filename
            guard FileManager.default.fileExists(atPath: installedOpenCodePluginPath) else { return false }
            guard let settings = readSettings(.opencode),
                  let plugins = settings["plugin"] as? [Any] else { return false }
            return plugins.contains { entry in
                if let s = entry as? String { return s.contains("seven-island-opencode.js") }
                return false
            }
        }
    }

    // MARK: - Install / Uninstall

    /// Merges Seven Island hook entries into the platform's settings file.
    /// `includePermission` only applies to Claude (Codex doesn't support it).
    /// OpenCode uses a JS plugin copied to ~/.config/opencode/plugins/ and
    /// registered in config.json's `plugin` array.
    static func install(
        _ platform: AgentPlatform,
        permissionIntercept: Bool = true,
        timeoutSeconds: Int = 60
    ) throws {
        switch platform {
        case .claude, .codex:
            try installShellHook(platform, permissionIntercept: permissionIntercept, timeoutSeconds: timeoutSeconds)
        case .opencode:
            try installOpenCodePlugin()
        }
    }

    /// Removes all Seven Island hook entries (leaves herdr/mintel alone),
    /// then writes back the cleaned settings. For OpenCode removes the plugin
    /// file and the config.json `plugin` entry.
    static func uninstall(_ platform: AgentPlatform) throws {
        switch platform {
        case .claude, .codex:
            try uninstallShellHook(platform)
        case .opencode:
            try uninstallOpenCodePlugin()
        }
    }

    private static func installShellHook(
        _ platform: AgentPlatform,
        permissionIntercept: Bool,
        timeoutSeconds: Int
    ) throws {
        let scriptPath = bundledScriptPath
        guard !scriptPath.isEmpty else {
            throw NSError(domain: "HookRegistrationManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bundled seven-island-hook.sh not found"])
        }

        // Migrate legacy: remove old script file if present
        let legacyScript = NSHomeDirectory() + "/.claude/hooks/seven-island.sh"
        if FileManager.default.fileExists(atPath: legacyScript) {
            try? FileManager.default.removeItem(atPath: legacyScript)
        }

        var settings = readSettings(platform) ?? [:]
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        let mk: (String, [String: Any]?) -> [[String: Any]] = { action, extra in
            var cmd = "bash '\(scriptPath)' \(platform.rawValue) \(action)"
            if let extra = extra, let t = extra["timeout"] { cmd += " \(t)" }
            return [["type": "command", "command": cmd]]
        }

        for key in hookEventKeys(platform) {
            let arr = hooks[key] as? [[String: Any]] ?? []
            hooks[key] = removeOurEntries(from: arr)
        }

        for ev in fireAndForgetEvents(platform) {
            let action = (ev == "SessionStart") ? "session" :
                         (ev == "Stop") ? "stop" : "hook \(ev)"
            let entry: [String: Any] = ["hooks": mk(action, nil)]
            hooks[ev] = mergeEntry(entry, into: hooks[ev] as? [[String: Any]] ?? [])
        }

        if platform == .claude && permissionIntercept {
            let entry: [String: Any] = ["hooks": mk("permission", ["timeout": timeoutSeconds])]
            hooks["PermissionRequest"] = mergeEntry(entry, into: hooks["PermissionRequest"] as? [[String: Any]] ?? [])
        }

        settings["hooks"] = hooks
        try writeSettings(platform, settings: settings)
    }

    private static func uninstallShellHook(_ platform: AgentPlatform) throws {
        guard var settings = readSettings(platform),
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hookEventKeys(platform) {
            hooks[key] = removeOurEntries(from: hooks[key] as? [[String: Any]] ?? [])
            if let arr = hooks[key] as? [[String: Any]], arr.isEmpty {
                hooks.removeValue(forKey: key)
            }
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(platform, settings: settings)
    }

    // MARK: - OpenCode plugin install/remove

    private static func installOpenCodePlugin() throws {
        let bundledPath = bundledOpenCodePluginPath
        guard !bundledPath.isEmpty else {
            throw NSError(domain: "HookRegistrationManager", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bundled seven-island-opencode.js not found"])
        }

        // 1. Ensure ~/.config/opencode/plugins/ exists
        let pluginsDir = (installedOpenCodePluginPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)

        // 2. Copy bundled JS plugin (overwrite any previous version)
        if FileManager.default.fileExists(atPath: installedOpenCodePluginPath) {
            try FileManager.default.removeItem(atPath: installedOpenCodePluginPath)
        }
        try FileManager.default.copyItem(atPath: bundledPath, toPath: installedOpenCodePluginPath)

        // 3. Merge a relative plugin entry in config.json
        var settings = readSettings(.opencode) ?? ["$schema": "https://opencode.ai/config.json"]
        var plugins = (settings["plugin"] as? [Any]) ?? []
        // Relative path is enough — the plugins dir is fixed at ~/.config/opencode/plugins/
        let entry = "plugins/seven-island-opencode.js"
        // Remove any of our previous entries first (idempotent)
        plugins = plugins.filter { item in
            if let s = item as? String { return !s.contains("seven-island-opencode.js") }
            return true
        }
        plugins.append(entry)
        settings["plugin"] = plugins
        try writeSettings(.opencode, settings: settings)
    }

    private static func uninstallOpenCodePlugin() throws {
        if FileManager.default.fileExists(atPath: installedOpenCodePluginPath) {
            try FileManager.default.removeItem(atPath: installedOpenCodePluginPath)
        }
        guard var settings = readSettings(.opencode),
              var plugins = settings["plugin"] as? [Any] else { return }
        plugins = plugins.filter { item in
            if let s = item as? String { return !s.contains("seven-island-opencode.js") }
            return true
        }
        if plugins.isEmpty {
            settings.removeValue(forKey: "plugin")
        } else {
            settings["plugin"] = plugins
        }
        try writeSettings(.opencode, settings: settings)
    }

    // MARK: - Stale path repair (called at app startup)

    /// If our bundled script path has changed (app moved/updated), rewrite
    /// every command referencing `seven-island-hook.sh` to use the new path.
    /// For OpenCode, if registered, refresh the plugin JS file from the new bundle.
    static func repairStalePathsIfNeeded() {
        let current = bundledScriptPath
        if !current.isEmpty {
            for platform in [AgentPlatform.claude, .codex] {
                if isRegistered(platform) || hasStaleEntry(platform) {
                    repairStalePaths(platform, newScriptPath: current)
                }
            }
        }
        // OpenCode: refresh plugin JS file if registered
        if isRegistered(.opencode) {
            try? installOpenCodePlugin()
        }
    }

    private static func hasStaleEntry(_ platform: AgentPlatform) -> Bool {
        guard let settings = readSettings(platform),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                if let hookList = entry["hooks"] as? [[String: Any]] {
                    for h in hookList {
                        if let cmd = h["command"] as? String, cmd.contains("seven-island-hook.sh") {
                            return !cmd.contains(bundledScriptPath)
                        }
                    }
                }
            }
        }
        return false
    }

    private static func repairStalePaths(_ platform: AgentPlatform, newScriptPath: String) {
        guard var settings = readSettings(platform),
              var hooks = settings["hooks"] as? [String: Any] else { return }
        var changed = false
        for (key, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            var newEntries: [[String: Any]] = []
            for entry in entries {
                guard let hookList = entry["hooks"] as? [[String: Any]] else {
                    newEntries.append(entry); continue
                }
                var newHooks: [[String: Any]] = []
                for h in hookList {
                    if var cmd = h["command"] as? String,
                       cmd.contains("seven-island-hook.sh") && !cmd.contains(newScriptPath) {
                        // Replace path: everything up to "bash '" stays, then new path.
                        if let range = cmd.range(of: "bash '") {
                            // Find the closing quote
                            let rest = String(cmd[range.upperBound...])
                            if let close = rest.firstIndex(of: "'") {
                                let args = String(rest[rest.index(after: close)...])
                                cmd = "bash '\(newScriptPath)'\(args)"
                                changed = true
                            }
                        }
                        var nh = h
                        nh["command"] = cmd
                        newHooks.append(nh)
                    } else {
                        newHooks.append(h)
                    }
                }
                var ne = entry
                ne["hooks"] = newHooks
                newEntries.append(ne)
            }
            hooks[key] = newEntries
        }
        if changed {
            settings["hooks"] = hooks
            try? writeSettings(platform, settings: settings)
        }
    }

    // MARK: - Private helpers

    private static func readSettings(_ platform: AgentPlatform) -> [String: Any]? {
        let path = settingsPath(platform)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parsed
    }

    private static func writeSettings(_ platform: AgentPlatform, settings: [String: Any]) throws {
        let path = settingsPath(platform)
        // Ensure parent directory exists (e.g. ~/.claude/)
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func hookEventKeys(_ platform: AgentPlatform) -> [String] {
        switch platform {
        case .claude:
            return ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure",
                    "Notification", "PreToolUse", "PostToolUse", "SessionEnd",
                    "PermissionRequest"]
        case .codex:
            return ["SessionStart", "UserPromptSubmit", "Stop", "SubagentStop",
                    "PreToolUse", "PostToolUse"]
        case .opencode:
            return [] // OpenCode doesn't use shell hooks
        }
    }

    private static func fireAndForgetEvents(_ platform: AgentPlatform) -> [String] {
        switch platform {
        case .claude:
            return ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure",
                    "Notification", "PreToolUse", "PostToolUse", "SessionEnd"]
        case .codex:
            return ["SessionStart", "UserPromptSubmit", "Stop", "SubagentStop",
                    "PreToolUse", "PostToolUse"]
        case .opencode:
            return [] // OpenCode doesn't use shell hooks
        }
    }

    /// Removes entries whose `hooks[*].command` references our script
    /// (matches both `seven-island-hook.sh` and legacy `seven-island.sh`).
    private static func removeOurEntries(from array: [[String: Any]]) -> [[String: Any]] {
        array.filter { entry in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return true }
            return !hookList.contains { h in
                guard let cmd = h["command"] as? String else { return false }
                return cmd.contains("seven-island-hook.sh") ||
                       cmd.contains("hooks/seven-island.sh")
            }
        }
    }

    /// Merge an entry avoiding duplicates: remove ours, then append fresh.
    private static func mergeEntry(_ entry: [String: Any], into array: [[String: Any]]) -> [[String: Any]] {
        let cleaned = removeOurEntries(from: array)
        return cleaned + [entry]
    }
}