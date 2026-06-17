//
//  PermissionTarget.swift
//  boringNotch
//
//  Captures the tool + tool_input of a Claude Code PermissionRequest so the
//  notch banner can offer richer decisions: show the full command, cache an
//  allow within the session, or persist a permission rule into the project's
//  .claude/settings.local.json.
//

import Foundation

struct PermissionTarget {
    /// Tool name as reported by Claude Code (e.g. "Bash", "Edit", "Read", "WebFetch").
    let toolName: String

    /// Raw tool_input dictionary as sent over the socket. Shape varies per tool.
    let toolInput: [String: Any]

    // MARK: - Convenience accessors

    /// Bash: "git push origin main". Edit/Write/Read: file_path. WebFetch: url. Else: empty.
    var displayCommand: String {
        if let s = toolInput["command"] as? String, !s.isEmpty { return s }
        if let s = toolInput["file_path"] as? String, !s.isEmpty { return s }
        if let s = toolInput["path"] as? String, !s.isEmpty { return s }
        if let s = toolInput["url"] as? String, !s.isEmpty { return s }
        return ""
    }

    // MARK: - Pattern encoding

    /// Encode this request into a Claude Code permissions.allow entry.
    /// See `.claude/settings.local.json` for example pattern syntax.
    /// Falls back to `<ToolName>(*)` when the input shape is unrecognized.
    func persistentAllowPattern() -> String {
        switch toolName {
        case "Bash":
            if let cmd = toolInput["command"] as? String, !cmd.isEmpty {
                return "Bash(\(cmd))"
            }
        case "Read":
            if let path = toolInput["file_path"] as? String ?? toolInput["path"] as? String,
               let dir = parentDir(of: path) {
                return "Read(\(dir)/**)"
            }
        case "Write":
            if let path = toolInput["file_path"] as? String, let dir = parentDir(of: path) {
                return "Write(\(dir)/**)"
            }
        case "Edit", "MultiEdit":
            if let path = toolInput["file_path"] as? String, let dir = parentDir(of: path) {
                return "\(toolName)(\(dir)/**)"
            }
        case "WebFetch":
            if let urlStr = toolInput["url"] as? String,
               let host = URL(string: urlStr)?.host, !host.isEmpty {
                return "WebFetch(domain:\(host))"
            }
        case "WebSearch":
            // No useful narrowing parameter — the whole tool either is allowed or not.
            return "WebSearch"
        default:
            break
        }
        return "\(toolName)(*)"
    }

    /// In-memory cache key for "allow within this session". Combines sessionId
    /// with the same pattern so that approving `Bash(rm foo)` doesn't silently
    /// allow `Bash(rm bar)`.
    func sessionAllowKey(sessionId: String) -> String {
        sessionId + "\u{1F}" + persistentAllowPattern()
    }

    // MARK: - Internal

    private func parentDir(of path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? nil : parent
    }
}
