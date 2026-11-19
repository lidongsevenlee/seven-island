import AppKit
import Foundation

@main
enum ClipboardHistoryStoreTests {
    private static var failures = 0

    static func main() throws {
        try testCopyingExistingTextPromotesAndPersistsIt()
        try testCopyingExistingImagePromotesIt()
        try testRecordingExistingTextPromotesIt()
        try testFileURLsAreCapturedCopiedAndPersisted()
        try testPNGIsCapturedAsImage()
        testHistoryLimitAndSensitiveTextFiltering()
        guard failures == 0 else { exit(1) }
        print("ClipboardHistoryStoreTests passed")
    }

    private static func testCopyingExistingTextPromotesAndPersistsIt() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = folder.appendingPathComponent("history.json")
        let store = ClipboardHistoryStore(pasteboard: pasteboard, persistenceURL: url)
        store.record("older text")
        store.record("newer text")
        let older = store.items[1]

        store.copyToPasteboard(older)

        expect(store.items.compactMap(\.content) == ["older text", "newer text"],
               "copying existing text promotes it to the top")
        expect(store.items.count == 2, "reusing text keeps one history entry per value")
        expect(pasteboard.string(forType: .string) == "older text", "copies the selected text")

        let savedItems = waitForSavedItems(store.items, at: url)
        expect(savedItems.compactMap(\.content) == ["older text", "newer text"],
               "persists the promoted text order")
    }

    private static func testCopyingExistingImagePromotesIt() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = folder.appendingPathComponent("history.json")
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let image = ClipboardHistoryItem(imageData: imageData)
        let text = ClipboardHistoryItem(content: "newer text")
        try JSONEncoder().encode([text, image]).write(to: url)
        let store = ClipboardHistoryStore(pasteboard: pasteboard, persistenceURL: url)

        store.copyToPasteboard(image)

        expect(store.items.first?.imageData == imageData, "copying an existing image promotes it to the top")
        expect(store.items.count == 2, "reusing an image keeps one history entry per value")
        expect(pasteboard.data(forType: .png) == imageData, "copies the selected image bytes")

        let savedItems = waitForSavedItems(store.items, at: url)
        expect(savedItems.first?.imageData == imageData, "persists the promoted image order")
    }

    private static func testRecordingExistingTextPromotesIt() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = folder.appendingPathComponent("history.json")
        let store = ClipboardHistoryStore(pasteboard: pasteboard, persistenceURL: url)
        store.record("older text")
        store.record("newer text")
        store.record("older text")
        expect(store.items.compactMap(\.content) == ["older text", "newer text"],
               "recording repeated text promotes it to the top")
        expect(waitForSavedItems(store.items, at: url) == store.items, "persists repeated text recording")
    }

    private static func testHistoryLimitAndSensitiveTextFiltering() {
        let items = [ClipboardHistoryItem(content: "second"), ClipboardHistoryItem(content: "third")]
        let limited = ClipboardHistoryStore.nextItems(inserting: "first", into: items, limit: 2)
        expect(limited.compactMap(\.content) == ["first", "second"], "respects the history limit")
        let filtered = ClipboardHistoryStore.nextItems(inserting: "sk-proj-example", into: items, limit: 2)
        expect(filtered == items, "retains sensitive text filtering")
    }

    private static func testFileURLsAreCapturedCopiedAndPersisted() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = folder.appendingPathComponent("history.json")
        let files = [
            folder.appendingPathComponent("report.pdf"),
            folder.appendingPathComponent("photo.png"),
        ]
        let store = ClipboardHistoryStore(pasteboard: pasteboard, persistenceURL: url)
        store.record("file:///copied-as-text.txt")
        expect(store.items.first?.kind == .text, "file paths copied as text stay in the text category")

        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })
        waitForPasteboard { store.items.first?.kind == .files }
        guard let item = store.items.first, item.kind == .files else {
            expect(false, "captures Finder-style file URLs as a file entry")
            return
        }
        expect(item.fileURLs == files.map(\.standardizedFileURL), "captures all copied file URLs")
        expect(item.matches("PHOTO.png"), "file searches match names case-insensitively")
        expect(item.preview == "report.pdf、photo.png", "shows the names in a multiple-file selection")

        store.record("newer text")
        store.copyToPasteboard(item)
        expect(store.items.first?.kind == .files, "copying a file entry promotes it")
        let copied = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        expect(copied == item.fileURLs, "copies native file URLs for pasting back into Finder")
        let saved = waitForSavedItems(store.items, at: url)
        expect(saved.first?.fileURLs == item.fileURLs, "persists the file references")

        let reverseOrder = ClipboardHistoryStore.nextItems(
            insertingFileURLs: files.reversed(), into: store.items, limit: 100
        )
        expect(reverseOrder.filter { $0.kind == .files }.count == 1, "deduplicates the same file selection across ordering")
    }

    private static func testPNGIsCapturedAsImage() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(pasteboard: pasteboard, persistenceURL: folder.appendingPathComponent("history.json"))
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        waitForPasteboard { store.items.first?.kind == .image }
        expect(store.items.first?.imageData == pngData, "captures a pasteboard item that supplies PNG")
    }

    private static func waitForPasteboard(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seven-island-clipboard-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func waitForSavedItems(_ expected: [ClipboardHistoryItem], at url: URL) -> [ClipboardHistoryItem] {
        let deadline = Date().addingTimeInterval(2)
        var savedItems: [ClipboardHistoryItem] = []
        repeat {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) {
                savedItems = decoded
                if savedItems == expected { break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return savedItems
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            failures += 1
        }
    }
}
