import AppKit
import SwiftUI
@testable import Seven_Island

@main
@MainActor
enum RowReorderAnimationTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fixture = DropFixture()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TestRows(fixture: fixture))
        window.orderBack(nil)
        defer { window.close() }
        settle(0.15)

        let target = fixture.slots[1]!
        let source = fixture.slots[3]!
        let cursor = CGPoint(x: target.minX + 50, y: target.maxY - 3)
        let translation = CGSize(width: 32, height: cursor.y - source.midY)
        let startY = source.minY + translation.height
        let siblingY = target.minY + source.height + 4
        fixture.reorder.update(3, at: cursor, translation: translation)
        settle(0.35)

        fixture.recording = true
        fixture.reorder.finish(3, at: cursor, animation: .easeOut(duration: 0.22)) { target in
            precondition(target == 1)
            return { fixture.order = [3, 1, 2] }
        }
        fixture.reorder.cancelGesture(for: 3)
        precondition(fixture.reorder.isSettling && fixture.order == [1, 2, 3])
        settle(0.45)

        let movingFrames = fixture.history[3, default: []]
        precondition(movingFrames.contains { (target.minX + 4...target.minX + 28).contains($0.minX) },
                     "the released row travels through intermediate positions")
        precondition(movingFrames.allSatisfy { (target.minY - 1...startY + 1).contains($0.minY) },
                     "the released row stays on its path into the slot")
        precondition(fixture.history[1, default: []].allSatisfy { abs($0.minY - siblingY) < 1 },
                     "the neighboring row stays in its previewed slot")
        precondition(fixture.order == [3, 1, 2] && fixture.reorder.source == nil)
        precondition(movingFrames.last?.origin == target.origin, "the layout takes over at the exact landing position")
        print("RowReorderAnimationTests passed")
    }

    private static func settle(_ duration: TimeInterval) {
        RunLoop.current.run(until: .now.addingTimeInterval(duration))
    }
}

@MainActor
@Observable
private final class DropFixture {
    let reorder = RowReorder<Int>(spacing: 4)
    var order = [1, 2, 3]
    @ObservationIgnored var slots: [Int: CGRect] = [:]
    @ObservationIgnored var history: [Int: [CGRect]] = [:]
    @ObservationIgnored var recording = false
}

private struct TestRows: View {
    let fixture: DropFixture

    var body: some View {
        VStack(spacing: 4) {
            ForEach(fixture.order, id: \.self) { id in
                Rectangle()
                    .frame(width: 200, height: id == 2 ? 52 : 30)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                        if fixture.recording { fixture.history[id, default: []].append(rect) }
                    }
                    .reorderRow(id, in: fixture.reorder, background: .white)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                        fixture.slots[id] = rect
                    }
            }
        }
        .frame(width: 260, height: 160)
        .onChange(of: fixture.order, initial: true) { _, order in fixture.reorder.setGroups([order]) }
    }
}
