import AppKit
import Combine
import Foundation

final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var items: [ClipboardHistoryItem] = []

    private let pasteboard: NSPasteboard
    private let persistenceURL: URL
    private var timer: Timer?
    private var lastChangeCount: Int

    init(
        pasteboard: NSPasteboard = .general,
        persistenceURL: URL = ClipboardHistoryStore.defaultPersistenceURL()
    ) {
        self.pasteboard = pasteboard
        self.persistenceURL = persistenceURL
        self.lastChangeCount = pasteboard.changeCount
        self.items = Self.loadItems(from: persistenceURL)
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func clear() {
        items = []
        save()
    }

    func copyToPasteboard(_ item: ClipboardHistoryItem) {
        pasteboard.clearContents()
        pasteboard.setString(item.content, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    func record(_ content: String) {
        items = Self.nextItems(inserting: content, into: items, limit: maxItemCount)
        save()
    }

    func reloadConfiguration() {
        items = Array(items.prefix(maxItemCount))
        save()
    }

    static func nextItems(
        inserting content: String,
        into currentItems: [ClipboardHistoryItem],
        limit: Int
    ) -> [ClipboardHistoryItem] {
        guard let normalized = normalizedContent(content) else {
            return currentItems
        }

        var next = currentItems.filter { $0.content != normalized }
        next.insert(ClipboardHistoryItem(content: normalized), at: 0)
        return Array(next.prefix(max(1, limit)))
    }

    static func normalizedContent(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 10_000 else {
            return nil
        }

        let lowercased = trimmed.lowercased()
        let sensitiveMarkers = [
            "private_key",
            "api_key",
            "access_token",
            "refresh_token",
            "bearer ",
            "sk-proj-",
            "sk-"
        ]
        if sensitiveMarkers.contains(where: { lowercased.contains($0) }) {
            return nil
        }

        return trimmed
    }

    static func defaultPersistenceURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folderName = Bundle.main.bundleIdentifier ?? "com.local.seven-island"
        return appSupport
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }

    private func pollPasteboard() {
        guard isEnabled else { return }
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if let string = pasteboard.string(forType: .string) {
            record(string)
        }
    }

    private var isEnabled: Bool {
        if let value = UserDefaults.standard.object(forKey: "sevenIslandClipboardHistoryEnabled") as? Bool {
            return value
        }
        return true
    }

    private var maxItemCount: Int {
        let stored = UserDefaults.standard.integer(forKey: "sevenIslandClipboardHistoryLimit")
        return min(max(stored == 0 ? 100 : stored, 1), 100)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(items)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }

    private static func loadItems(from url: URL) -> [ClipboardHistoryItem] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) else {
            return []
        }
        return items
    }
}
