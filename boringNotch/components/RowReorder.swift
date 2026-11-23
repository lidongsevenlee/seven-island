import SwiftUI

@MainActor
@Observable
final class RowReorder<ID: Hashable> {
    struct RowFrame: Equatable, Sendable {
        let rect: CGRect
        let viewport: CGRect?
    }

    private struct Preview: Equatable {
        let target: ID
        let offsets: [ID: CGFloat]
    }

    private struct PendingDrop {
        let id = UUID()
        let apply: () -> Void
    }

    private let spacing: CGFloat
    @ObservationIgnored private var groups: [[ID]] = []
    @ObservationIgnored private var frames: [ID: RowFrame] = [:]
    private var preview: Preview?
    private var pendingDrop: PendingDrop?
    private(set) var source: ID?
    private(set) var translation = CGSize.zero
    var isSettling: Bool { pendingDrop != nil }

    init(spacing: CGFloat = 0) {
        self.spacing = spacing
    }

    func setGroups(_ groups: [[ID]]) {
        guard self.groups != groups else { return }
        self.groups = groups
        reset()
    }

    func setFrame(_ frame: RowFrame?, for id: ID) {
        frames[id] = frame
    }

    func update(_ id: ID, at point: CGPoint, translation: CGSize) {
        guard pendingDrop == nil, let group = groups.first(where: { $0.contains(id) }), group.count > 1 else { return }
        if source != id { source = id }
        self.translation = translation
        let next = placement(of: id, in: group, at: point)
        if preview != next { preview = next }
    }

    func finish(_ id: ID, at point: CGPoint, animation: Animation? = nil, prepareDrop: (ID) -> (() -> Void)?) {
        guard source == id, pendingDrop == nil else { return }
        guard let group = groups.first(where: { $0.contains(id) }),
              let placement = placement(of: id, in: group, at: point), placement.target != id,
              let apply = prepareDrop(placement.target) else {
            withAnimation(animation) { clearPreview() }
            return
        }

        let drop = PendingDrop(apply: apply)
        // Slide into the projected slot, then hand its position over to the committed layout.
        withAnimation(animation, completionCriteria: .removed) {
            pendingDrop = drop
            preview = placement
            translation = CGSize(width: 0, height: offset(for: id))
        } completion: {
            self.completeDrop(drop.id)
        }
    }

    func cancelGesture(for id: ID) {
        if source == id && pendingDrop == nil { clearPreview() }
    }

    func reset() {
        if let pendingDrop {
            completeDrop(pendingDrop.id)
        } else {
            clearPreview()
        }
    }

    private func completeDrop(_ id: UUID) {
        guard let pendingDrop, pendingDrop.id == id else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.pendingDrop = nil
            pendingDrop.apply()
            clearPreview()
        }
    }

    private func clearPreview() {
        guard source != nil else { return }
        source = nil
        preview = nil
        translation = .zero
    }

    func offset(for id: ID) -> CGFloat {
        preview?.offsets[id] ?? 0
    }

    private func placement(of id: ID, in group: [ID], at point: CGPoint) -> Preview? {
        guard let from = group.firstIndex(of: id), let sourceFrame = frames[id]?.rect,
              let to = group.firstIndex(where: { id in
                  guard let frame = frames[id], frame.viewport?.contains(point) != false else { return false }
                  return frame.rect.insetBy(dx: 0, dy: -spacing / 2).contains(point)
              }), let targetFrame = frames[group[to]]?.rect else { return nil }

        var offsets: [ID: CGFloat] = [:]
        let stride = sourceFrame.height + spacing
        if to < from {
            for index in to..<from { offsets[group[index]] = stride }
            offsets[id] = targetFrame.minY - sourceFrame.minY
        } else if to > from {
            for index in (from + 1)...to { offsets[group[index]] = -stride }
            offsets[id] = targetFrame.maxY - sourceFrame.maxY
        }
        return Preview(target: group[to], offsets: offsets)
    }
}

private struct ReorderHandle<ID: Hashable>: ViewModifier {
    let id: ID
    let reorder: RowReorder<ID>
    let prepareDrop: (ID) -> (() -> Void)?
    @GestureState private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .updating($isDragging) { _, isDragging, _ in isDragging = true }
                    .onChanged { value in
                        reorder.update(id, at: value.location, translation: value.translation)
                    }
                    .onEnded { value in
                        reorder.finish(id, at: value.location, animation: reduceMotion ? nil : .easeOut(duration: 0.22),
                                       prepareDrop: prepareDrop)
                    }
            )
            .onChange(of: isDragging) { _, isDragging in
                if !isDragging { reorder.cancelGesture(for: id) }
            }
    }
}

private struct DragTranslation: ViewModifier, Animatable {
    var translation: CGSize

    var animatableData: CGSize.AnimatableData {
        get { translation.animatableData }
        set { translation.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(translation)
    }
}

private struct ReorderRow<ID: Hashable, Content: View>: View {
    let id: ID
    let reorder: RowReorder<ID>
    let background: Color
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lifted = reorder.source == id
        let shift = reorder.offset(for: id)
        let translation = lifted ? reorder.translation : .zero
        let settling = lifted && reorder.isSettling
        let animation: Animation? = reduceMotion ? nil : .smooth(duration: 0.22)

        content
            .background {
                if lifted {
                    RoundedRectangle(cornerRadius: 8).fill(background)
                        .shadow(color: .black.opacity(settling ? 0 : 0.22), radius: 5, y: 2)
                }
            }
            .offset(y: lifted ? 0 : shift)
            .animation(animation, value: shift)
            .modifier(DragTranslation(translation: translation))
            .background {
                if lifted {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(settling ? 0 : 0.12))
                        .offset(y: shift)
                        .animation(animation, value: shift)
                        .allowsHitTesting(false)
                }
            }
            .animation(animation, value: lifted)
            .zIndex(lifted ? 1 : 0)
            // Measure the layout slot outside the animated offsets.
            .onGeometryChange(for: RowReorder<ID>.RowFrame.self) { geometry in
                let rect = geometry.frame(in: .global)
                let viewport = geometry.bounds(of: .scrollView)?.offsetBy(dx: rect.minX, dy: rect.minY)
                return RowReorder<ID>.RowFrame(rect: rect, viewport: viewport)
            } action: { frame in
                reorder.setFrame(frame, for: id)
            }
            .onDisappear {
                reorder.setFrame(nil, for: id)
                if reorder.source == id { reorder.reset() }
            }
    }
}

@MainActor
extension View {
    func reorderHandle<ID>(for id: ID, in reorder: RowReorder<ID>, prepareDrop: @escaping (ID) -> (() -> Void)?) -> some View {
        modifier(ReorderHandle(id: id, reorder: reorder, prepareDrop: prepareDrop))
    }

    func reorderRow<ID>(_ id: ID, in reorder: RowReorder<ID>, background: Color) -> some View {
        ReorderRow(id: id, reorder: reorder, background: background, content: self)
    }
}
