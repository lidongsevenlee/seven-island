//
//  AgentBrandLogos.swift
//  boringNotch
//
//  SwiftUI Shapes representing the official brand glyphs for each AI agent
//  (Claude / Codex / OpenCode). Used in BoringHeader tab indicator, the
//  HookNotification banner, and HooksActivityView session cards.
//

import SwiftUI

// MARK: - SVG path utilities

/// Parses an SVG path `d` string into a SwiftUI `Path` and auto-scales/centers
/// the result into `rect`. Supports M/L/H/V/C/Q/S/T/Z + lowercase relative
/// variants, implicit repeated command groups (e.g. `q1 2 3 4 5 6 7 8` repeats
/// the quadratic twice), and the SVG moveto-after-first-pair-becomes-lineto rule.
/// S/s (smooth cubic) and T/t (smooth quadratic) reflect the previous curve's
/// control point per the SVG spec. Used by the brand-logo Shapes below.
func pathFromSVG(_ d: String, in rect: CGRect) -> Path {
    let chars = Array(d)
    let n = chars.count
    var path = Path()
    var i = 0
    var start = CGPoint.zero
    var current = CGPoint.zero
    var prevCubic: CGPoint? = nil
    var prevQuad: CGPoint? = nil
    var cmd: Character? = nil

    func readNumber() -> Double? {
        while i < n, chars[i].isWhitespace || chars[i] == "," { i += 1 }
        guard i < n else { return nil }
        let s = i
        if chars[i] == "+" || chars[i] == "-" { i += 1 }
        while i < n, chars[i].isNumber { i += 1 }
        if i < n, chars[i] == "." {
            i += 1
            while i < n, chars[i].isNumber { i += 1 }
        }
        if i < n, chars[i] == "e" || chars[i] == "E" {
            i += 1
            if i < n, chars[i] == "+" || chars[i] == "-" { i += 1 }
            while i < n, chars[i].isNumber { i += 1 }
        }
        guard i > s else { return nil }
        return Double(String(chars[s..<i]))
    }

    func invalidateCubic() { prevCubic = nil }
    func invalidateQuad() { prevQuad = nil }

    while i < n {
        while i < n, chars[i].isWhitespace || chars[i] == "," { i += 1 }
        guard i < n else { break }
        if chars[i].isLetter {
            cmd = chars[i]
            i += 1
        }
        guard let c = cmd, let up = c.uppercased().first else { break }
        let relative = c.isLowercase

        switch up {
        case "M":
            guard let x = readNumber(), let y = readNumber() else { break }
            let pt = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            path.move(to: pt); start = pt; current = pt
            cmd = relative ? "l" : "L"
            invalidateCubic(); invalidateQuad()
        case "L":
            guard let x = readNumber(), let y = readNumber() else { break }
            let pt = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            path.addLine(to: pt); current = pt
            invalidateCubic(); invalidateQuad()
        case "H":
            guard let x = readNumber() else { break }
            let pt = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
            path.addLine(to: pt); current = pt
            invalidateCubic(); invalidateQuad()
        case "V":
            guard let y = readNumber() else { break }
            let pt = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
            path.addLine(to: pt); current = pt
            invalidateCubic(); invalidateQuad()
        case "C":
            guard let x1 = readNumber(), let y1 = readNumber(),
                  let x2 = readNumber(), let y2 = readNumber(),
                  let x = readNumber(), let y = readNumber() else { break }
            let cp1 = relative ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
            let cp2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
            let pt = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            path.addCurve(to: pt, control1: cp1, control2: cp2)
            prevCubic = cp2; invalidateQuad(); current = pt
        case "Q":
            guard let x1 = readNumber(), let y1 = readNumber(),
                  let x = readNumber(), let y = readNumber() else { break }
            let cp = relative ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
            let pt = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            path.addQuadCurve(to: pt, control: cp)
            prevQuad = cp; invalidateCubic(); current = pt
        case "S":
            guard let x2 = readNumber(), let y2 = readNumber(),
                  let x = readNumber(), let y = readNumber() else { break }
            let cp1 = prevCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            let cp2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
            let pt = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            path.addCurve(to: pt, control1: cp1, control2: cp2)
            prevCubic = cp2; invalidateQuad(); current = pt
        case "T":
            guard let x = readNumber(), let y = readNumber() else { break }
            let cp = prevQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            let pt = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            path.addQuadCurve(to: pt, control: cp)
            prevQuad = cp; invalidateCubic(); current = pt
        case "Z":
            path.closeSubpath()
            current = start
            invalidateCubic(); invalidateQuad()
            // Z takes no params; force re-read of next command letter.
            cmd = nil
        default:
            cmd = nil
        }
    }

    let bounds = path.boundingRect
    guard bounds.width > 0, bounds.height > 0 else { return path }
    let scale = min(rect.width / bounds.width, rect.height / bounds.height)
    let tx = rect.midX - bounds.midX * scale
    let ty = rect.midY - bounds.midY * scale
    let t = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    var cgPath = path.cgPath
    var transform = t
    guard let transformed = cgPath.copy(using: &transform) else { return path }
    return Path(transformed)
}

// MARK: - Claude

/// Anthropic Claude "sunburst" logo (rounded mark used by the Claude Code app).
/// Source: Anthropic brand assets.
struct ClaudeStarLogo: Shape {
    private static let pathData = """
    M5.07306 17.7192L9.99106 14.9614L10.0721 14.7199L9.99106 14.5854H9.74786L8.92369 14.5352 \
    L6.11341 14.46L3.68143 14.3597L1.31701 14.2344L0.722529 14.109L0.168579 13.3694 \
    L0.222623 13.0059L0.722529 12.6675L1.43861 12.7301L3.0194 12.843L5.39733 13.0059 \
    L7.11322 13.1062L9.66679 13.3694H10.0721L10.1262 13.2065L9.99106 13.1062L9.88297 13.0059 \
    L7.42397 11.3387L4.76231 9.58378L3.37068 8.56843L2.62758 8.05448L2.24927 7.57814 \
    L2.08714 6.52518L2.76269 5.77306L3.68143 5.83574L3.91112 5.89842L4.84338 6.61293 \
    L6.82949 8.15476L9.4236 10.0601L9.80191 10.3735L9.95424 10.2707L9.97755 10.198 \
    L9.80191 9.9097L8.39676 7.36504L6.89705 4.77024L6.2215 3.69221L6.04585 3.05291 \
    C5.97781 2.78463 5.93777 2.56267 5.93777 2.28826L6.70789 1.2353L7.14024 1.09741 \
    L8.18059 1.2353L8.61294 1.61136L9.26147 3.09052L10.3018 5.40954L11.9231 8.56843 \
    L12.396 9.50857L12.6527 10.3735L12.7473 10.6367H12.9094V10.4863L13.0445 8.70631 \
    L13.2877 6.52518L13.5309 3.71728L13.612 2.92756L14.0038 1.97488L14.7875 1.46093 \
    L15.3954 1.74925L15.8954 2.46376L15.8278 2.92756L15.5306 4.85799L14.9496 7.87899 \
    L14.5713 9.9097H14.7875L15.0442 9.64646L16.071 8.29265L17.7869 6.13659L18.5435 5.28419 \
    L19.4352 4.34404L20.0027 3.89277H21.0836L21.8672 5.07109L21.5159 6.28701L20.408 7.69096 \
    L19.4893 8.88181L18.172 10.6467L17.3545 12.0658L17.4278 12.1828L17.6248 12.166 \
    L20.5972 11.5267L22.205 11.2384L24.1235 10.9125L24.9882 11.3136L25.0828 11.7273 \
    L24.745 12.5672L22.6914 13.0686L20.2864 13.5575L16.7051 14.4005L16.6655 14.4324 \
    L16.7123 14.5018L18.3273 14.648L19.0164 14.6856H20.7053L23.8533 14.9238L24.6775 15.4628 \
    L25.1639 16.1272L25.0828 16.6411L23.8128 17.2804L22.1104 16.8793L18.1247 15.9266 \
    L16.7601 15.5882H16.5709V15.701L17.7058 16.8166L19.8 18.6969L22.4076 21.1288 \
    L22.5428 21.7304L22.205 22.2068L21.8537 22.1566L19.5568 20.4268L18.6651 19.6496 \
    L16.6655 17.9573H16.5304V18.1328L16.9897 18.8097L19.4352 22.4826L19.5568 23.6107 \
    L19.3812 23.9743L18.7462 24.1999L18.0571 24.0745L16.6114 22.0564L15.1387 19.8 \
    L13.9498 17.7693L13.8062 17.86L13.0986 25.4158L12.7743 25.8044L12.0177 26.0927 \
    L11.3827 25.6164L11.0449 24.8392L11.3827 23.2974L11.788 21.2917L12.1123 19.6997 \
    L12.4095 17.7192L12.5911 17.0575L12.575 17.0133L12.43 17.0376L10.9368 19.0855 \
    L8.66698 22.1566L6.87002 24.0745L6.43767 24.25L5.69457 23.8614L5.76212 23.172 \
    L6.18096 22.5578L8.66698 19.3989L10.1667 17.4309L11.1333 16.3012L11.1239 16.1378 \
    L11.0705 16.1332L4.46507 20.4393L3.28961 20.5897L2.7762 20.1134L2.84375 19.3362 \
    L3.08695 19.0855L5.07306 17.7192Z
    """

    func path(in rect: CGRect) -> Path {
        pathFromSVG(Self.pathData, in: rect)
    }
}

// MARK: - Codex (OpenAI Codex blossom)

/// The official Codex mark — the gradient "blossom"/spiral flower.
/// Path data from codex-logo.svg (250×250 viewBox). Uses relative moveto,
/// quadratic (`q`) and cubic (`c`) Beziers with implicit repeated groups.
/// Rendered here as a single solid silhouette; the brand accent color is set
/// to the codex purple in `AgentPlatform.brandColorRGB` so the silhouette reads
/// as the Codex mark even without the gradient.
struct CodexSpiralLogo: Shape {
    private static let pathData = """
    m84.3 5.1q3.7-1.5 7.7-2.6 3.9-1 7.9-1.6 4-0.5 8.1-0.6 4 0 8 0.5 20.7 2.4 37.1 17.7 0.1 0.1 0.4 0.3 0.1 0 0.2 0 0 0 0.2 0 0 0 0.1 0 0 0 0.1 0 5.2-1.4 10.7-1.9 5.4-0.4 10.7 0.1 5.5 0.4 10.7 1.9 5.2 1.3 10.1 3.6l0.6 0.4 1.6 0.8q5.2 2.5 9.7 6.1 4.7 3.4 8.6 7.7 3.8 4.3 6.9 9.2 3 4.8 5.2 10.2 4.3 10.5 4.3 22.1 0.2 2.1 0 4.2-0.1 2.2-0.2 4.3-0.3 2.1-0.7 4.3-0.4 2.1-0.9 4.1 0 0.2 0 0.4 0 0.2 0 0.5 0 0.1 0.1 0.4 0.1 0.1 0.3 0.3 12.3 12.6 16.3 30 6 29.7-12.2 53.5l-1.9 2.2q-3 3.5-6.5 6.4-3.4 3.1-7.3 5.5-3.8 2.4-8.1 4.2-4.1 1.9-8.5 3.2-0.3 0-0.4 0.2-0.3 0-0.4 0.1-0.1 0.1-0.3 0.4 0 0.1-0.1 0.3c-2.7 7.7-5.3 14.2-10.2 20.7-12.5 16.5-30.8 25.5-51.5 25.5q-24.6-0.1-43.6-18.1-0.2-0.1-0.4-0.2-0.2-0.1-0.4-0.1-0.2 0-0.3 0-0.3 0-0.4 0c-5.4 1.7-10.9 1.9-16.7 1.9q-3.5 0-7-0.5-3.4-0.4-6.9-1.2-3.3-0.8-6.6-2-3.3-1.2-6.4-2.8-3.3-1.6-6.4-3.6-3-2-5.8-4.3-3-2.3-5.5-5-2.5-2.6-4.6-5.6c-2.2-2.7-4.3-5.4-5.8-8.5q-0.8-1.6-1.6-3.2-0.6-1.7-1.3-3.3-0.7-1.7-1.2-3.4-0.5-1.6-1-3.4-1.1-4-1.6-7.9-0.6-4-0.6-8 0-4 0.6-8 0.4-4 1.4-8 0 0 0-0.1 0-0.1 0-0.1 0.2-0.2 0.2-0.3 0-0.1-0.2-0.1 0-0.2 0-0.3 0-0.1-0.1-0.1 0-0.2 0-0.2-0.1-0.1-0.1-0.1-2.4-2.5-4.6-5.2-2.1-2.7-4-5.4-1.7-3-3.2-6-1.5-3.1-2.6-6.3-0.8-2-1.3-4.1-0.7-2-1.1-4-0.4-2.1-0.7-4.2-0.2-2.2-0.4-4.3-0.2-2.8-0.1-5.6 0-2.8 0.3-5.4 0.1-2.8 0.6-5.6 0.4-2.8 1.1-5.5 7-23.1 26.9-36.3 4.3-2.9 8.2-4.5 4.5-1.9 9-3.2 0.2 0 0.3-0.1 0.1-0.2 0.3-0.3 0.1 0 0.1-0.3 0.1-0.1 0.1-0.2 1-3.1 2.2-6 1-2.9 2.5-5.7 1.5-3 3.2-5.6 1.7-2.7 3.7-5.1 2.5-3.2 5.3-5.9 3-2.8 6.1-5.4 3.2-2.4 6.8-4.4 3.5-2 7.2-3.5zm48.3 146.4c-2.3 0.1-4.4 1-6 2.8-1.5 1.6-2.4 3.7-2.4 5.9 0 2.3 0.9 4.4 2.4 6.2 1.6 1.6 3.7 2.5 6 2.6h50.4c2.4 0.1 4.8-0.6 6.5-2.4 1.7-1.6 2.8-4 2.8-6.4 0-2.4-1.1-4.7-2.8-6.3-1.7-1.8-4.1-2.6-6.5-2.4zm-56.7-64.9c-1.2-1.9-3-3.4-5.3-3.9-2.2-0.5-4.5-0.3-6.5 0.9-2 1.1-3.5 3-4.1 5.2-0.7 2.2-0.4 4.6 0.6 6.5l17.7 30.9-17.5 29.5c-1.2 2-1.6 4.5-1.1 6.8 0.7 2.3 2.1 4.1 4.1 5.3 2 1.2 4.4 1.6 6.7 0.9 2.2-0.5 4.2-1.9 5.4-3.9l20.1-34.1q0.7-0.9 0.9-2.1 0.3-1.1 0.3-2.3 0-1.2-0.3-2.2-0.2-1.2-0.8-2.2z
    """

    func path(in rect: CGRect) -> Path {
        pathFromSVG(Self.pathData, in: rect)
    }
}

// MARK: - OpenCode (terminal monitor)

/// OpenCode official mark — faithfully reproduced from opencode-logo-light.svg
/// (240×300 viewBox). The SVG has two elements: a frame (outer rect with an
/// inner rectangular hole) and a bar (the bottom half of the inner area).
///
/// Because the two elements use different colours in the source SVG (#211E1E
/// frame + #CFCECD bar), they can't be expressed as a single `Shape` with one
/// `.fill()`. Instead `OpenCodeLogoView` renders them as two explicit shapes
/// stacked in a ZStack, matching the SVG's geometry exactly.
///
/// On the notch's dark background the "light" variant's dark frame would be
/// invisible, so both elements use the brand accent colour (light grey #CFCECD)
/// — the gap between frame and bar shows the dark background, producing the
/// recognisable OpenCode glyph.

/// Frame shape: outer rectangle (0,0)–(240,300) with an inner rectangular hole
/// (60,60)–(180,240). Designed for **even-odd** fill so the inner area becomes
/// a hole regardless of subpath winding direction.
struct OpenCodeFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 240, rect.height / 300)
        let w = 240 * scale
        let h = 300 * scale
        let ox = rect.midX - w / 2
        let oy = rect.midY - h / 2

        var p = Path()
        // Outer rect
        p.addRect(CGRect(x: ox, y: oy, width: w, height: h))
        // Inner rect (hole — even-odd fill makes this a hole)
        let innerW = 120 * scale
        let innerH = 180 * scale
        p.addRect(CGRect(x: ox + 60 * scale, y: oy + 60 * scale,
                         width: innerW, height: innerH))
        return p
    }
}

/// Bar shape: rectangle (60,120)–(180,240) — the bottom half of the inner area.
struct OpenCodeBarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 240, rect.height / 300)
        let w = 240 * scale
        let h = 300 * scale
        let ox = rect.midX - w / 2
        let oy = rect.midY - h / 2

        let barW = 120 * scale
        let barH = 120 * scale
        return Path(CGRect(x: ox + 60 * scale, y: oy + 120 * scale,
                           width: barW, height: barH))
    }
}

/// Composite view rendering the full OpenCode mark: frame (even-odd fill) + bar.
struct OpenCodeLogoView: View {
    var opacity: Double = 1.0

    var body: some View {
        let color = Color(
            red: 0.811, green: 0.807, blue: 0.803  // #CFCECD
        ).opacity(opacity)

        ZStack {
            OpenCodeFrameShape()
                .fill(color, style: FillStyle(eoFill: true))
            OpenCodeBarShape()
                .fill(color)
        }
    }
}

// MARK: - Generic brand-icon view

/// Renders the correct brand glyph for an `AgentPlatform` at a given size and
/// opacity. For Claude and Codex this is a simple `Shape` + `.fill()`. For
/// OpenCode it delegates to `OpenCodeLogoView` which needs two stacked shapes
/// to faithfully reproduce the SVG's two-tone geometry.
///
/// Usage:
///
///     BrandIconView(platform: session.platform, size: 11)
///     BrandIconView(platform: session.platform, size: 9, opacity: 0.7)
struct BrandIconView: View {
    let platform: AgentPlatform
    var size: CGFloat = 11
    var opacity: Double = 1.0

    var body: some View {
        Group {
            switch platform {
            case .claude:
                ClaudeStarLogo()
                    .fill(brandColor.opacity(opacity))
            case .codex:
                CodexSpiralLogo()
                    .fill(brandColor.opacity(opacity))
            case .opencode:
                OpenCodeLogoView(opacity: opacity)
            }
        }
        .frame(width: size, height: size)
    }

    private var brandColor: Color {
        let rgb = platform.brandColorRGB
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

// MARK: - SwiftUI helper to Draw the platform-specific brand glyph

/// Type-erased Shape wrapper (avoids shadowing SwiftUI's `AnyShape`).
/// Used for single-fill logos (Claude, Codex). OpenCode uses `BrandIconView`
/// instead because its SVG requires two stacked shapes.
extension AgentPlatform {
    var brandIconShape: ErasedShape {
        switch self {
        case .claude:   return ErasedShape(ClaudeStarLogo())
        case .codex:    return ErasedShape(CodexSpiralLogo())
        case .opencode: return ErasedShape(OpenCodeFrameShape())  // frame only; prefer BrandIconView
        }
    }
}

struct ErasedShape: Shape {
    private let _path: (CGRect) -> Path

    init<S: Shape>(_ s: S) { _path = { s.path(in: $0) } }
    init(_ path: @escaping (CGRect) -> Path) { _path = path }

    func path(in rect: CGRect) -> Path { _path(rect) }
}
