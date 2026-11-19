import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct ScreenshotAnnotation {
    enum Tool: Hashable {
        case rectangle, ellipse, line, polyline, arrow, pencil, marker, mosaic, blur, text, eraser

        var usesArea: Bool { self == .marker || self == .mosaic || self == .blur || self == .eraser }
        var usesColor: Bool { self != .mosaic && self != .blur && self != .eraser }
        var followsPointer: Bool { self == .pencil || usesArea }
    }

    struct Style {
        var color = NSColor(srgbRed: 0.94, green: 0.22, blue: 0.30, alpha: 1)
        var size = 1
        var usesArea = false

        var lineWidth: CGFloat { [2, 4, 8][size] }
        var textSize: CGFloat { [14, 20, 30][size] }
    }

    let tool: Tool
    let style: Style
    var points: [CGPoint]
    var text = ""

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
        guard let start = points.first else { return true }
        if tool == .text { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if tool.followsPointer, !style.usesArea { return false }
        return !points.contains { $0 != start }
    }
}

struct ScreenshotAnnotationHistory {
    private var entries: [ScreenshotAnnotation] = []
    private var position = 0

    var visible: ArraySlice<ScreenshotAnnotation> { entries.prefix(position) }
    var canUndo: Bool { position > 0 }
    var canRedo: Bool { position < entries.count }

    mutating func append(_ annotation: ScreenshotAnnotation) {
        guard !annotation.isEmpty else { return }
        entries.removeSubrange(position...)
        entries.append(annotation)
        position += 1
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
        case .rectangle:
            context.stroke(rect)
        case .ellipse:
            context.strokeEllipse(in: rect)
        case .line, .polyline, .pencil:
            context.addPath(strokeArea(annotation.points, width: style.lineWidth))
            context.fillPath()
        case .arrow:
            drawArrow(from: start, to: end, width: style.lineWidth, in: context)
        case .marker:
            context.setFillColor(style.color.withAlphaComponent(0.36).cgColor)
            context.addPath(style.usesArea ? CGPath(rect: rect, transform: nil)
                            : strokeArea(annotation.points, width: style.lineWidth * 4))
            context.fillPath()
        case .mosaic, .blur, .eraser:
            let area = style.usesArea ? CGPath(rect: rect, transform: nil) : strokeArea(annotation.points, width: style.lineWidth * 7)
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
            let label = NSAttributedString(string: annotation.text, attributes: [
                .font: NSFont.systemFont(ofSize: style.textSize, weight: .semibold), .foregroundColor: style.color
            ])
            label.draw(at: start)
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

    private func strokeArea(_ points: [CGPoint], width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if points.count == 1, let point = points.first {
            path.addEllipse(in: CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width))
            return path
        }
        path.addLines(between: points)
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
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
