import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct ScreenshotAnnotation {
    enum Tool: Hashable {
        case selection, rectangle, ellipse, line, polyline, arrow, pencil, marker, mosaic, blur, text, eraser

        var usesArea: Bool { self == .marker || self == .mosaic || self == .blur || self == .eraser }
        var usesColor: Bool { self != .mosaic && self != .blur && self != .eraser }
        var followsPointer: Bool { self == .pencil || usesArea }
    }

    struct Style {
        enum AppearanceChange {
            case size(Int)
            case color(NSColor)
        }

        var color = NSColor(srgbRed: 0.94, green: 0.22, blue: 0.30, alpha: 1)
        var size = 1
        var usesArea = false

        var lineWidth: CGFloat { [2, 4, 8][size] }
        var textFont: NSFont { .systemFont(ofSize: [14, 20, 30][size], weight: .semibold) }

        mutating func apply(_ change: AppearanceChange) {
            switch change {
            case .size(let size): self.size = size
            case .color(let color): self.color = color
            }
        }
    }

    let id = UUID()
    let tool: Tool
    var style: Style
    var points: [CGPoint]
    var text = ""
    var textScale: CGFloat = 1
    var textWidth: CGFloat = .greatestFiniteMagnitude

    init(tool: Tool, style: Style, points: [CGPoint], text: String = "") {
        self.tool = tool
        self.style = style
        self.points = points
        self.text = text
    }

    mutating func extend(to point: CGPoint, constrained: Bool) {
        guard let start = points.first else { return }
        if tool.followsPointer, !style.usesArea {
            if points.last != point { points.append(point) }
            return
        }
        var end = point
        if constrained {
            let dx = point.x - start.x
            let dy = point.y - start.y
            if tool == .rectangle || tool == .ellipse || style.usesArea {
                let length = min(abs(dx), abs(dy))
                end = CGPoint(x: start.x + (dx < 0 ? -length : length), y: start.y + (dy < 0 ? -length : length))
            } else {
                let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(dx, dy)
                end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            }
        }
        points = [start, end]
    }

    var isEmpty: Bool {
        guard let start = points.first, tool != .selection else { return true }
        if tool == .text { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if tool.followsPointer, !style.usesArea { return false }
        return !points.contains { $0 != start }
    }

    var textLayout: (label: NSAttributedString, size: CGSize) {
        let font = style.textFont
        let scaledFont = textScale == 1 ? font : NSFont.systemFont(ofSize: font.pointSize * textScale, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: scaledFont, .foregroundColor: style.color]
        let measure = NSAttributedString(string: text + "\u{200B}", attributes: attributes)
        let limit = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        let width = max(1, ceil(measure.boundingRect(with: limit, options: [.usesLineFragmentOrigin, .usesFontLeading]).width))
        let height = ceil(measure.boundingRect(with: CGSize(width: width, height: limit.height),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        return (NSAttributedString(string: text, attributes: attributes), CGSize(width: width, height: height))
    }

    private var geometryBounds: CGRect {
        guard let origin = points.first else { return .zero }
        if tool == .text { return CGRect(origin: origin, size: textLayout.size) }
        let minX = points.min(by: { $0.x < $1.x })!.x
        let maxX = points.max(by: { $0.x < $1.x })!.x
        let minY = points.min(by: { $0.y < $1.y })!.y
        let maxY = points.max(by: { $0.y < $1.y })!.y
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var editBounds: CGRect {
        let rect = geometryBounds
        let width = max(12, rect.width)
        let height = max(12, rect.height)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    func hitTest(_ point: CGPoint) -> Bool {
        guard !isEmpty, tool != .eraser else { return false }
        let bounds = geometryBounds
        let area = bounds.insetBy(dx: -4, dy: -4)
        if style.usesArea, tool.usesArea { return area.contains(point) }
        switch tool {
        case .ellipse:
            return CGPath(ellipseIn: area, transform: nil).contains(point)
        case .rectangle, .text:
            return area.contains(point)
        default:
            let width: CGFloat
            switch tool {
            case .marker: width = style.lineWidth * 4
            case .mosaic, .blur: width = style.lineWidth * 7
            case .arrow: width = style.lineWidth * 2
            default: width = style.lineWidth
            }
            let padding = width / 2 + 4
            return bounds.insetBy(dx: -padding, dy: -padding).contains(point)
                && strokeArea(width: width + 8).contains(point)
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        var annotation = self
        annotation.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return annotation
    }

    func resized(to target: CGRect, using handle: ScreenshotResizeHandle) -> Self {
        let original = editBounds
        let scaleX = target.width / original.width
        let scaleY = target.height / original.height
        var annotation = self
        if tool == .text {
            let scale = abs(scaleX - 1) >= abs(scaleY - 1) ? scaleX : scaleY
            annotation.textScale = min(16, max(0.2, textScale * scale))
            annotation.textWidth = min(CGFloat(100_000), textWidth * annotation.textScale / textScale)
            let size = annotation.textLayout.size
            annotation.points = [CGPoint(x: handle.x == .minimum ? original.maxX - size.width : target.minX,
                                         y: handle.y == .minimum ? original.maxY - size.height : target.minY)]
        } else {
            annotation.points = points.map {
                CGPoint(x: target.minX + ($0.x - original.minX) * scaleX,
                        y: target.minY + ($0.y - original.minY) * scaleY)
            }
        }
        return annotation
    }

    func strokeArea(width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if points.count == 1, let point = points.first {
            path.addEllipse(in: CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width))
            return path
        }
        path.addLines(between: points)
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }
}

struct ScreenshotAnnotationHistory {
    private var revisions: [[ScreenshotAnnotation]] = [[]]
    private var position = 0

    var visible: ArraySlice<ScreenshotAnnotation> { revisions[position][...] }
    var canUndo: Bool { position > 0 }
    var canRedo: Bool { position + 1 < revisions.count }

    mutating func append(_ annotation: ScreenshotAnnotation) {
        guard !annotation.isEmpty else { return }
        record(revisions[position] + [annotation])
    }

    mutating func replace(at index: Int, with annotation: ScreenshotAnnotation) {
        var entries = revisions[position]
        entries[index] = annotation
        record(entries)
    }

    mutating func remove(at index: Int) {
        var entries = revisions[position]
        entries.remove(at: index)
        record(entries)
    }

    private mutating func record(_ entries: [ScreenshotAnnotation]) {
        revisions.removeSubrange((position + 1)...)
        revisions.append(entries)
        position += 1
    }

    mutating func apply(_ change: ScreenshotAnnotation.Style.AppearanceChange, toLast tool: ScreenshotAnnotation.Tool) {
        guard let last = revisions[position].last, last.tool == tool else { return }
        for revision in position..<revisions.count {
            if let index = revisions[revision].firstIndex(where: { $0.id == last.id }) {
                revisions[revision][index].style.apply(change)
            }
        }
    }

    mutating func undo() {
        if canUndo { position -= 1 }
    }

    mutating func redo() {
        if canRedo { position += 1 }
    }
}

@MainActor
final class ScreenshotAnnotationRenderer {
    private let display: ScreenshotDisplay
    private lazy var filters = CIContext()
    private var effectImages: [ScreenshotAnnotation.Tool: CGImage] = [:]

    init(display: ScreenshotDisplay) {
        self.display = display
    }

    func draw(_ annotations: ArraySlice<ScreenshotAnnotation>, draft: ScreenshotAnnotation?,
              clippedTo selection: CGRect, in context: CGContext) {
        guard !annotations.isEmpty || draft != nil else { return }
        context.saveGState()
        context.clip(to: selection)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for annotation in annotations { draw(annotation, in: context) }
        if let draft { draw(draft, in: context) }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    func capture(_ selection: CGRect, annotations: ArraySlice<ScreenshotAnnotation>) -> CGImage? {
        let pixels = display.pixelRect(for: selection)
        guard !pixels.isEmpty, !pixels.isNull else { return nil }
        if annotations.isEmpty { return display.image.cropping(to: pixels) }
        for tool in Set(annotations.map(\.tool)) where tool == .mosaic || tool == .blur {
            guard effectImage(for: tool) != nil else { return nil }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scaleX = display.pixelBounds.width / display.bounds.width
        let scaleY = display.pixelBounds.height / display.bounds.height
        context.translateBy(x: -pixels.minX, y: pixels.maxY)
        context.scaleBy(x: scaleX, y: -scaleY)
        drawImage(display.image, in: context)
        // Use the same outward pixel alignment for the image and its annotations.
        let aligned = CGRect(x: pixels.minX / scaleX, y: pixels.minY / scaleY,
                             width: pixels.width / scaleX, height: pixels.height / scaleY)
        draw(annotations, draft: nil, clippedTo: aligned, in: context)
        return context.makeImage()
    }

    private func draw(_ annotation: ScreenshotAnnotation, in context: CGContext) {
        guard let start = annotation.points.first, let end = annotation.points.last else { return }
        let style = annotation.style
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
                          height: abs(end.y - start.y))
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(style.color.cgColor)
        context.setFillColor(style.color.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.tool {
        case .selection:
            break
        case .rectangle:
            context.stroke(rect)
        case .ellipse:
            context.strokeEllipse(in: rect)
        case .line, .polyline, .pencil:
            context.addPath(annotation.strokeArea(width: style.lineWidth))
            context.fillPath()
        case .arrow:
            drawArrow(from: start, to: end, width: style.lineWidth, in: context)
        case .marker:
            context.setFillColor(style.color.withAlphaComponent(0.36).cgColor)
            context.addPath(style.usesArea ? CGPath(rect: rect, transform: nil)
                            : annotation.strokeArea(width: style.lineWidth * 4))
            context.fillPath()
        case .mosaic, .blur, .eraser:
            let area = style.usesArea ? CGPath(rect: rect, transform: nil) : annotation.strokeArea(width: style.lineWidth * 7)
            if annotation.tool == .eraser {
                context.setBlendMode(.clear)
                context.addPath(area)
                context.fillPath()
            } else if let image = effectImage(for: annotation.tool) {
                context.addPath(area)
                context.clip()
                drawImage(image, in: context)
            }
        case .text:
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.current = previous }
            let layout = annotation.textLayout
            layout.label.draw(with: CGRect(origin: start, size: layout.size), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, in context: CGContext) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return }
        let directionX = (end.x - start.x) / length
        let directionY = (end.y - start.y) / length
        let head = min(length, max(10, 4 * width))
        let base = CGPoint(x: end.x - head * directionX, y: end.y - head * directionY)
        context.move(to: start)
        context.addLine(to: CGPoint(x: (base.x + end.x) / 2, y: (base.y + end.y) / 2))
        context.strokePath()
        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x + head * 0.38 * directionY, y: base.y - head * 0.38 * directionX))
        context.addLine(to: CGPoint(x: base.x - head * 0.38 * directionY, y: base.y + head * 0.38 * directionX))
        context.closePath()
        context.fillPath()
    }

    private func effectImage(for tool: ScreenshotAnnotation.Tool) -> CGImage? {
        if let image = effectImages[tool] { return image }
        let input = CIImage(cgImage: display.image)
        let scale = Float(display.pixelBounds.width / display.bounds.width)
        let clamped = input.clampedToExtent()
        let output: CIImage?
        if tool == .mosaic {
            let filter = CIFilter.pixellate()
            filter.inputImage = clamped
            filter.scale = 12 * scale
            filter.center = .zero
            output = filter.outputImage
        } else {
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = clamped
            filter.radius = 10 * scale
            output = filter.outputImage
        }
        let rendered = output.flatMap { filters.createCGImage($0, from: input.extent) }
        effectImages[tool] = rendered
        return rendered
    }

    private func drawImage(_ image: CGImage, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: display.bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: display.bounds)
        context.restoreGState()
    }
}
