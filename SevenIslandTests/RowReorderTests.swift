import Foundation
@testable import Seven_Island

@main
@MainActor
enum RowReorderTests {
    static func main() {
        let reorder = RowReorder<Int>(spacing: 4)
        reorder.setGroups([[1, 2, 3], [4, 5]])
        let viewport = CGRect(x: 0, y: 0, width: 200, height: 154)
        for (id, y, height) in [(1, 10, 30), (2, 44, 52), (3, 100, 30), (4, 134, 30), (5, 168, 30)] {
            reorder.setFrame(.init(rect: CGRect(x: 20, y: y, width: 160, height: height), viewport: viewport), for: id)
        }

        let firstRow = CGPoint(x: 50, y: 25)
        let thirdRow = CGPoint(x: 50, y: 115)
        let outside = CGPoint(x: 195, y: 25)
        let otherGroup = CGPoint(x: 50, y: 143)

        func drop(_ source: Int, at point: CGPoint) -> Int? {
            var committedTarget: Int?
            reorder.finish(source, at: point) { target in
                { committedTarget = target }
            }
            return committedTarget
        }

        reorder.update(3, at: firstRow, translation: CGSize(width: 3, height: -90))
        precondition(reorder.source == 3 && reorder.translation.height == -90)
        precondition(reorder.offset(for: 1) == 34 && reorder.offset(for: 2) == 34 && reorder.offset(for: 3) == -90)
        precondition(reorder.offset(for: 4) == 0)

        reorder.update(3, at: outside, translation: CGSize(width: 145, height: -90))
        precondition(reorder.source == 3 && reorder.offset(for: 1) == 0, "moving outside restores the rows during the drag")
        reorder.update(3, at: firstRow, translation: CGSize(width: 3, height: -90))
        precondition(drop(3, at: outside) == nil, "rechecks the pointer on mouse-up")
        precondition(reorder.source == nil && reorder.offset(for: 2) == 0)

        reorder.update(1, at: thirdRow, translation: CGSize(width: 0, height: 90))
        precondition(reorder.offset(for: 2) == -34 && reorder.offset(for: 3) == -34 && reorder.offset(for: 1) == 90)
        precondition(drop(1, at: thirdRow) == 3, "commits the previewed slot")

        reorder.update(1, at: otherGroup, translation: CGSize(width: 0, height: 118))
        precondition(drop(1, at: otherGroup) == nil, "separate groups have separate drop regions")
        let clippedRow = CGPoint(x: 50, y: 183)
        reorder.update(4, at: clippedRow, translation: CGSize(width: 0, height: 36))
        precondition(drop(4, at: clippedRow) == nil, "rows outside the scroll viewport cannot receive drops")

        reorder.update(3, at: firstRow, translation: CGSize(width: 0, height: -90))
        reorder.cancelGesture(for: 3)
        precondition(drop(3, at: firstRow) == nil && reorder.offset(for: 1) == 0)
        print("RowReorderTests passed")
    }
}
