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
    /// Serial queue for all disk I/O and image transcoding so the main runloop
    /// never hitches on copy events.
    private let ioQueue = DispatchQueue(label: "com.local.seven-island.clipboard-io", qos: .utility)
    private var saveDebounce: DispatchWorkItem?

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
        scheduleSave()
    }

    func copyToPasteboard(_ item: ClipboardHistoryItem) {
        pasteboard.clearContents()
        if let imageData = item.imageData {
            pasteboard.setData(imageData, forType: .png)
        } else if let text = item.content {
            pasteboard.setString(text, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
    }

    func record(_ content: String) {
        items = Self.nextItems(inserting: content, into: items, limit: maxItemCount)
        scheduleSave()
    }

    func recordImage(from tiffData: Data) {
        // Transcoding PNG with NSBitmapImageRep is expensive — push it off the
        // main thread so a copied screenshot doesn't stutter the UI.
        ioQueue.async { [weak self] in
            guard let self,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [.compressionFactor: 0.8])
            else { return }
            DispatchQueue.main.async {
                self.items = Self.nextItems(insertingImageData: pngData, into: self.items, limit: self.maxItemCount)
                self.scheduleSave()
            }
        }
    }

    func reloadConfiguration() {
        items = Array(items.prefix(maxItemCount))
        scheduleSave()
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

    static func nextItems(
        insertingImageData data: Data,
        into currentItems: [ClipboardHistoryItem],
        limit: Int
    ) -> [ClipboardHistoryItem] {
        var next = currentItems.filter { $0.imageData != data }
        next.insert(ClipboardHistoryItem(imageData: data), at: 0)
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
        } else if let tiffData = pasteboard.data(forType: .tiff) {
            recordImage(from: tiffData)
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

    /// Coalesce rapid mutations (e.g. consecutive copies) and write on the
    /// utility queue so the main thread never blocks on disk.
    private func scheduleSave() {
        saveDebounce?.cancel()
        let snapshot = items
        let url = persistenceURL
        let work = DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Failed to save clipboard history: \(error.localizedDescription)")
            }
        }
        saveDebounce = work
        ioQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private static func loadItems(from url: URL) -> [ClipboardHistoryItem] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) else {
            return []
        }
        return items
    }
}
