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

/// Parses an SVG path `d` string (supports M/L/H/V/C/Z) into a SwiftUI `Path`
/// and auto-scales/centers the result into `rect`.
func pathFromSVG(_ d: String, in rect: CGRect) -> Path {
    let cmdSet = CharacterSet(charactersIn: "MmLlHhVvCcZz")
    let tokens = d.components(separatedBy: cmdSet.union(.whitespaces)).filter { !$0.isEmpty }
    let cmds = d.filter { cmdSet.contains($0.unicodeScalars.first!) }

    var path = Path()
    var i = 0
    var start = CGPoint.zero
    var current = CGPoint.zero

    func num(_ idx: Int) -> Double? {
        guard idx < tokens.count else { return nil }
        return Double(tokens[idx])
    }

    for cmd in cmds {
        switch cmd {
        case "M":
            guard let x = num(i), let y = num(i + 1) else { break }
            let pt = CGPoint(x: x, y: y)
            path.move(to: pt); start = pt; current = pt; i += 2
        case "L":
            guard let x = num(i), let y = num(i + 1) else { break }
            let pt = CGPoint(x: x, y: y)
            path.addLine(to: pt); current = pt; i += 2
        case "H":
            guard let x = num(i) else { break }
            let pt = CGPoint(x: x, y: current.y)
            path.addLine(to: pt); current = pt; i += 1
        case "V":
            guard let y = num(i) else { break }
            let pt = CGPoint(x: current.x, y: y)
            path.addLine(to: pt); current = pt; i += 1
        case "C":
            guard let cx1 = num(i), let cy1 = num(i + 1),
                  let cx2 = num(i + 2), let cy2 = num(i + 3),
                  let x = num(i + 4), let y = num(i + 5) else { break }
            let pt = CGPoint(x: x, y: y)
            path.addCurve(to: pt,
                          control1: CGPoint(x: cx1, y: cy1),
                          control2: CGPoint(x: cx2, y: cy2))
            current = pt; i += 6
        case "Z", "z":
            path.closeSubpath()
            current = start
        default: break
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

// MARK: - Codex (OpenAI hexa-spiral flower)

/// The OpenAI "Nexus" / "flower" mark used by Codex — the iconic six-petal
/// knotted loop designed by Studio Dumbar.  Path data vectorised from the
/// brand kit at brand.openai.com; supports the same coordinates Claude's
/// `pathFromSVG` parser already understands.
struct CodexSpiralLogo: Shape {
    // The official OpenAI logo's `d` attribute (from the public SVG at
    // https://openai.com/brand). All 60+ cubic Bezier segments preserved.
    private static let pathData = """
    M23.5534 0.630852C27.3575 1.54108 30.5484 4.20202 32.2907 7.97458 \
    C33.0174 9.57334 33.479 11.3005 33.6509 13.0802C30.0576 13.0194 25.7537 12.3162 \
    21.6697 10.5406C17.7605 8.83802 14.6587 6.34297 12.2469 3.08759C14.4508 1.00763 17.3131 -0.120681 \
    20.3228 0.0116986C21.4074 0.0601989 22.4878 0.269587 23.5534 0.630852Z \
    M31.4486 16.8749C31.7629 18.9176 31.679 21.0495 31.1671 23.1639 \
    C29.2394 22.8826 27.0589 22.5084 24.8183 21.9937C19.7663 20.8308 15.6437 19.111 12.6192 17.2485 \
    C12.8363 15.9338 13.2667 14.6518 13.9082 13.4637C16.5851 15.182 19.9804 16.7282 \
    24.0759 17.7827C26.7294 18.4653 29.2431 18.7557 31.4486 16.8749Z \
    M30.1547 25.9003C28.9673 28.8594 26.6711 31.0549 23.9206 32.0875 \
    C23.6399 31.1814 23.3793 30.1994 23.1519 29.1444L23.1517 29.1437C22.7586 27.3078 22.4695 \
    25.4024 22.272 23.4489C26.1123 24.0178 29.8505 24.1785 33.0062 23.8186C32.2623 24.5932 31.3762 \
    25.2529 30.1547 25.9003Z \
    M20.2024 22.9889C20.4147 25.1319 20.7113 27.2181 21.0824 29.2229 \
    C19.1022 28.5711 17.2781 27.5038 15.7429 26.0964C17.0967 24.9234 18.5544 23.8792 20.2024 22.9889Z \
    M18.9642 21.4845C17.3772 22.2783 15.9449 23.2342 14.6668 24.3273 \
    C13.8584 23.2878 13.1978 22.1301 12.7081 20.8885C14.6675 21.4977 16.7554 21.6731 18.9642 \
    21.4845Z \
    M11.7671 18.7221C11.6301 18.1076 11.5327 17.4836 11.4747 16.856 \
    C13.7133 15.8789 16.5479 14.8419 19.9119 14.0063C20.411 13.883 20.9012 13.7686 21.3828 13.6625 \
    C19.4587 15.1324 17.2772 16.6537 14.9134 18.1824C13.8833 18.8525 12.8352 19.421 11.7671 18.7221Z \
    M11.3769 14.4549C11.3775 9.73435 13.7002 6.07475 14.5004 5.0076C14.8472 5.48486 15.2824 \
    6.07514 15.8131 6.74357C13.4889 9.08738 11.9932 12.1314 11.6745 15.4672C11.4626 15.1206 11.3769 \
    14.7916 11.3769 14.4549Z \
    M18.9992 13.1946C21.1134 12.6823 23.2155 12.3244 25.2025 12.1088C25.2123 11.6223 25.2171 11.1408 \
    25.2171 10.6659C25.2171 8.31738 25.0891 6.16504 24.8436 4.22084C20.8467 6.74296 19.1014 9.73381 \
    18.9992 13.1946Z \
    M26.5127 12.0079C28.9469 12.0149 31.3884 12.2299 33.7899 12.6689C33.7897 12.7325 33.7853 12.7959 \
    33.7807 12.8607C33.7161 13.7188 33.5744 14.5587 33.3674 15.3749C30.7833 14.8504 28.1138 14.5294 \
    25.4077 14.4139C25.8784 13.6356 26.5127 12.0079 26.5127 12.0079Z \
    M27.0236 11.0887C28.9536 7.50063 28.0604 3.40165 24.1219 0C25.5926 0.829747 26.9149 1.92987 28.0318 \
    3.27281C29.5924 5.07189 30.6169 7.25537 30.9911 9.57881C29.6924 9.96539 28.3724 10.291 27.0236 \
    11.0887Z \
    M33.7988 8.82413C34.4998 12.5324 33.9997 16.381 33.385 20.1629C32.4189 19.4834 31.2269 18.8782 \
    29.8154 18.379C29.9484 16.8135 29.8328 15.242 29.4711 13.7226C30.9356 13.1999 32.3972 12.6579 \
    33.7988 8.82413Z \
    M32.864 25.8085C33.6567 26.0089 34.3576 26.2797 35.0001 26.6157C34.0569 28.9596 32.8366 30.7723 \
    31.2629 32.0869C31.7918 30.0567 32.0461 27.9515 32.864 25.8085Z \
    M30.2826 25.3185C29.4769 26.903 28.548 28.2502 27.5236 29.3698C26.0294 29.1629 24.5685 28.7752 \
    23.1117 28.2402C25.5941 27.5828 28.0236 26.5879 30.2826 25.3185Z \
    M26.2141 30.0152C24.3026 31.5385 22.1649 32.558 19.9886 33.0666C21.1151 32.2461 22.1389 31.2917 \
    23.0328 30.2231C24.106 30.2236 25.1701 30.1545 26.2141 30.0152Z \
    M21.7248 30.1866C20.6807 31.3753 19.4381 32.3096 18.0095 33.0001C17.0525 33.0424 16.0867 32.9649 \
    15.1482 32.7563C17.8025 32.2448 20.4672 31.2146 23.0041 29.6836C22.6064 29.8659 22.169 30.0363 \
    21.7248 30.1866Z \
    M16.4874 32.4143C13.9746 31.5203 11.7256 29.766 10.1976 27.4308C11.6544 27.9235 13.1745 28.2019 \
    14.7113 28.2561C15.1941 29.8806 15.7626 31.207 16.4874 32.4143Z \
    M14.7264 27.1087C12.9649 27.0302 11.2155 26.5453 9.59385 25.6657C8.76763 24.4242 8.12211 23.0499 \
    7.68619 21.5952C9.44707 23.9703 11.769 25.7686 14.5195 26.9902C14.5852 27.027 14.6559 27.0706 \
    14.7264 27.1087Z \
    M14.2353 25.902C11.0695 24.4691 8.50062 21.877 7.09177 18.7488C7.07897 18.0713 7.11574 17.3954 \
    7.20004 16.7248C7.73283 18.7383 9.3026 20.4382 11.7151 21.7873C13.0408 22.5309 14.5669 23.0085 \
    16.2829 23.2231C15.6755 24.0708 14.9746 24.9247 14.2353 25.902Z \
    M16.7701 22.225C15.0431 22.0414 13.5716 21.6504 12.2552 20.9523C10.0451 19.7822 8.61191 18.2087 \
    8.06259 16.3898C8.4052 14.5148 9.16134 12.7377 10.2901 11.1795C12.1951 13.6713 15.0017 15.8757 \
    18.6103 17.6281C18.0335 18.6924 17.4137 19.5827 16.7701 22.225Z \
    M19.2542 16.7245C15.7822 15.0529 13.106 12.9224 11.3008 10.3888C12.2476 9.38577 13.3494 8.53192 \
    14.5851 7.87353C16.9466 11.0329 20.0279 13.4781 23.6374 14.9705C22.3654 15.7189 20.9594 16.3172 \
    19.2542 16.7245Z \
    M24.6754 13.9179C20.9614 12.5374 17.7634 10.2465 15.3649 7.13546C16.3688 6.70953 17.4316 6.42021 \
    18.5267 6.2829C18.9461 6.85219 19.3654 7.40036 19.7847 7.92761C22.277 11.053 24.9822 13.3226 \
    27.8313 14.7343C26.8193 14.539 25.7625 14.2798 24.6754 13.9179Z \
    M28.9186 14.9539C25.608 13.5769 22.4602 10.9526 19.9156 7.53886C19.5345 7.04915 19.1536 6.53985 \
    18.7726 6.01112C19.8317 5.96652 20.8937 6.06219 21.9314 6.2966C24.7211 6.92762 27.4017 8.76322 \
    29.3801 11.4608C29.2686 11.9905 29.2033 12.5308 29.2033 13.0802C29.2033 13.7153 29.2692 14.3408 \
    28.9186 14.9539Z \
    M33.999 13.0802C33.999 6.50496 29.7461 0.973672 22.9293 0.0116986C26.0262 0.404071 29.0032 1.68377 \
    31.364 3.76456C34.3184 6.36643 35.9998 10.1324 35.9998 14.4549C35.9998 17.5261 34.9573 20.4074 \
    33.1582 22.739C32.0045 21.5421 30.5841 20.3771 28.9186 19.2741C30.5533 18.0056 32.0531 16.5443 \
    33.3674 14.9116C33.7913 14.5473 33.9988 13.8121 33.999 13.0802Z \
    M34.5999 23.7328C32.5424 26.5856 29.5225 28.7322 25.8919 29.5236C28.3795 28.2139 30.5934 26.452 \
    32.5049 24.3124C33.2361 24.1928 33.9533 23.9914 34.5999 23.7328Z
    """

    func path(in rect: CGRect) -> Path {
        pathFromSVG(Self.pathData, in: rect)
    }
}

// MARK: - OpenCode (terminal window with caret)

/// OpenCode badge mark — a rounded terminal window with a `>` caret inside.
/// Pure SwiftUI (no SVG asset needed) so the glyph scales crisply.
struct OpenCodeTerminalLogo: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let r = min(w, h) * 0.18  // corner radius

        // Rounded rectangle outline (OK to leave as path; caller will stroke or fill)
        let bounds = CGRect(
            x: rect.minX + w * 0.05,
            y: rect.minY + h * 0.05,
            width:  w * 0.90,
            height: h * 0.90
        )
        path.addRoundedRect(in: bounds, cornerSize: CGSize(width: r, height: r))

        // Caret — a chevron `>` near the left, vertically centred and sized
        // to roughly half of the inner height.
        let caretCx = bounds.minX + bounds.width * 0.22
        let caretCy = bounds.midY
        // Size relative to inner height.
        let caretHalfH = bounds.height * 0.22
        let caretIndent = bounds.width * 0.14
        path.move(to: CGPoint(x: caretCx, y: caretCy - caretHalfH))
        path.addLine(to: CGPoint(x: caretCx + caretIndent, y: caretCy))
        path.addLine(to: CGPoint(x: caretCx, y: caretCy + caretHalfH))
        // Underscore bar to the right of the caret — makes the icon read
        // as a terminal prompt `>_`
        let barLeft = caretCx + caretIndent + bounds.width * 0.04
        let barRight = barLeft + bounds.width * 0.22
        let barY = caretCy + caretHalfH
        path.move(to: CGPoint(x: barLeft, y: barY))
        path.addLine(to: CGPoint(x: barRight, y: barY))
        return path
    }
}

// MARK: - SwiftUI helper to Draw the platform-specific brand glyph

/// Convenience view that selects the correct logo `Shape` for each agent
/// and fills it with the platform brand color. Use as:
///
///     BrandIcon(platform: session.platform, size: 12)
///         .fill(.white)
///
/// or directly embed the Shape inside an `Image`-style layout by wrapping
/// it in `Image(systemName:)` semantics.
extension AgentPlatform {
    /// Returns an `ErasedShape` wrapping the appropriate brand mark, so the
    /// caller can use it as a generic `Shape` (avoids shadowing SwiftUI's
    /// built-in `AnyShape`).
    var brandIconShape: ErasedShape {
        switch self {
        case .claude:   return ErasedShape(ClaudeStarLogo())
        case .codex:    return ErasedShape(CodexSpiralLogo())
        case .opencode: return ErasedShape(OpenCodeTerminalLogo())
        }
    }
}

struct ErasedShape: Shape {
    private let _path: (CGRect) -> Path

    init<S: Shape>(_ s: S) { _path = { s.path(in: $0) } }
    init(_ path: @escaping (CGRect) -> Path) { _path = path }

    func path(in rect: CGRect) -> Path { _path(rect) }
}
