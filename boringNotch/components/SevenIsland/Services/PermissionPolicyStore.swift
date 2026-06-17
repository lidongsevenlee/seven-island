//
//  PermissionPolicyStore.swift
//  boringNotch
//
//  Persists "always allow" decisions to the project's
//  `<cwd>/.claude/settings.local.json` so Claude Code itself can short-circuit
//  the PermissionRequest hook on the next invocation.
//

import Foundation
import os.log

@MainActor
final class PermissionPolicyStore {
    static let shared = PermissionPolicyStore()

    private init() {}

    /// Append `pattern` to the `permissions.allow` array of
    /// `<cwd>/.claude/settings.local.json`. Idempotent — does nothing if the
    /// pattern already exists. Returns `true` on success.
    @discardableResult
    func appendPersistentAllow(pattern: String, cwd: String) -> Bool {
        guard !pattern.isEmpty, !cwd.isEmpty else { return false }
        let dirURL = URL(fileURLWithPath: cwd)
            .appendingPathComponent(".claude", isDirectory: true)
        let fileURL = dirURL.appendingPathComponent("settings.local.json")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            os_log(.error, "[PermissionPolicyStore] mkdir failed at %@: %@",
                   dirURL.path, error.localizedDescription)
            return false
        }

        // Read existing file (or start empty)
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [Any] ?? []

        // Idempotency: skip if exact match already present
        let alreadyPresent = allow.contains { ($0 as? String) == pattern }
        if !alreadyPresent {
            allow.append(pattern)
        }
        permissions["allow"] = allow
        root["permissions"] = permissions

        do {
            // Pretty-print, no sorted keys (Claude Code's own writes don't sort
            // either, so we'd produce noisy diffs against existing files).
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted]
            )
            // Append a trailing newline like most editors do.
            var bytes = data
            if bytes.last != 0x0A { bytes.append(0x0A) }
            try bytes.write(to: fileURL, options: .atomic)
            os_log(.info, "[PermissionPolicyStore] %@ pattern=%@ at %@",
                   alreadyPresent ? "noop (exists)" : "appended",
                   pattern, fileURL.path)
            return true
        } catch {
            os_log(.error, "[PermissionPolicyStore] write failed at %@: %@",
                   fileURL.path, error.localizedDescription)
            return false
        }
    }
}
