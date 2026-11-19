import ApplicationServices
import Foundation
import OSLog

struct AppleMusicAccessibilityLyrics: Sendable {
    struct Row {
        let text: String
        let timeLabels: [String]
    }

    let text: String
    let syncedLines: [LyricsDisplayText.SyncedLine]

    init?(rows: [Row], duration: Double) {
        guard rows.count > 1 else { return nil }
        let parsed = rows.map { row -> (text: String, time: Double?) in
            if row.text.hasPrefix("["), let close = row.text.firstIndex(of: "]"),
               let time = Self.parseTime(String(row.text[row.text.index(after: row.text.startIndex)..<close])) {
                return (row.text[row.text.index(after: close)...].trimmingCharacters(in: .whitespaces), time)
            }
            return (row.text, row.timeLabels.lazy.compactMap(Self.parseTime).first)
        }
        guard parsed.allSatisfy({ !$0.text.isEmpty }) else { return nil }
        text = parsed.map(\.text).joined(separator: "\n")
        let timed = parsed.compactMap { line -> LyricsDisplayText.SyncedLine? in
            guard let time = line.time else { return nil }
            return (time, line.text)
        }
        let ordered = zip(timed, timed.dropFirst()).allSatisfy { $0.0.time < $0.1.time }
        syncedLines = timed.count == parsed.count && ordered && (duration <= 0 || timed.last!.time <= duration)
            ? timed : []
    }

    static func read(pid: pid_t, title: String, duration: Double) async -> Self? {
        let task = Task.detached(priority: .utility) {
            Reader().read(pid: pid, title: title, duration: duration)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func parseTime(_ label: String) -> Double? {
        let fields = label.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0].allSatisfy(\.isNumber),
              let minutes = Int(fields[0]), fields[1].count >= 2,
              fields[1].allSatisfy({ $0.isNumber || $0 == "." }),
              let seconds = Double(fields[1]), seconds >= 0, seconds < 60 else { return nil }
        return Double(minutes) * 60 + seconds
    }

    private struct Reader {
        private static let logger = Logger(subsystem: "com.local.seven-island", category: "AppleMusicLyrics")
        private let deadline = ProcessInfo.processInfo.systemUptime + 1.0

        private var canRead: Bool {
            !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline
        }

        func read(pid: pid_t, title: String, duration: Double) -> AppleMusicAccessibilityLyrics? {
            guard AXIsProcessTrusted() else {
                Self.logger.debug("Lyrics accessibility permission unavailable")
                return nil
            }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
            for window in windows.prefix(4) where canRead {
                guard let pane = findLyricsPane(in: window, matching: title) else { continue }
                let rows = lyricRows(in: pane)
                guard canRead, let result = AppleMusicAccessibilityLyrics(rows: rows, duration: duration) else { return nil }
                Self.logger.debug("Lyrics panel exposed \(rows.count) lines and \(result.syncedLines.count) synchronized lines")
                return result
            }
            return nil
        }

        private func findLyricsPane(in window: AXUIElement, matching song: String) -> AXUIElement? {
            var pending = [window]
            var pane: AXUIElement?
            var matchesSong = false
            for _ in 0..<200 {
                guard canRead, let element = pending.popLast() else { break }
                let identifier = value(element, kAXIdentifierAttribute) as? String ?? ""
                let role = value(element, kAXRoleAttribute) as? String ?? ""
                if identifier.hasPrefix("Music.miniPlayer.title"), let title = label(element) {
                    matchesSong = title.compare(song, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                } else if role == kAXGroupRole || role == kAXScrollAreaRole,
                          ["lyrics", "歌词", "歌詞"].contains(label(element)?.lowercased() ?? "") {
                    pane = element
                }
                if matchesSong, let pane { return pane }
                if role != kAXTableRole && role != kAXOutlineRole && role != kAXScrollAreaRole {
                    pending.append(contentsOf: children(element).reversed())
                }
            }
            return nil
        }

        private func lyricRows(in pane: AXUIElement) -> [Row] {
            let scrollArea = children(pane).first { value($0, kAXRoleAttribute) as? String == kAXScrollAreaRole } ?? pane
            var pending = Array(children(scrollArea).reversed())
            var rows: [Row] = []
            for _ in 0..<300 {
                guard canRead, let element = pending.popLast() else { break }
                let role = value(element, kAXRoleAttribute) as? String
                if role == kAXButtonRole || role == kAXStaticTextRole {
                    guard let text = label(element) else { continue }
                    let times = [kAXHelpAttribute, kAXValueDescriptionAttribute, kAXValueAttribute, kAXDescriptionAttribute]
                        .compactMap { value(element, $0) as? String }
                        .filter { $0 != text }
                    rows.append(Row(text: text, timeLabels: times))
                } else if role != kAXScrollBarRole {
                    pending.append(contentsOf: children(element).reversed())
                }
            }
            return pending.isEmpty ? rows : []
        }

        private func children(_ element: AXUIElement) -> [AXUIElement] {
            value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }

        private func label(_ element: AXUIElement) -> String? {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let label = value(element, attribute) as? String {
                    let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                }
            }
            return nil
        }

        private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard canRead, AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
    }
}
