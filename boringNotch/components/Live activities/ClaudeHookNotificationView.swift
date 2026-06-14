//
//  ClaudeHookNotificationView.swift
//  boringNotch
//
//  Compact notification in the closed notch for Claude Code session events.
//  - blocked: shows permission details + Allow / Deny / custom-reason buttons
//  - idle (completed): shows a simple "done" banner
//

import SwiftUI

/// Lightweight state holder shared between AppDelegate callback and the view.
@MainActor
final class ClaudeHookNotificationState: ObservableObject {
    static let shared = ClaudeHookNotificationState()
    @Published var label: String = ""
    @Published var isBlocked: Bool = false
    private init() {}
}

// MARK: - Heights

/// Notch bar height when showing a "done" notification
let claudeHookIdleHeight: CGFloat   = 52
/// Notch bar height when showing a permission request with buttons
let claudeHookBlockedHeight: CGFloat = 88

// MARK: - Main view

struct ClaudeHookNotificationView: View {
    @ObservedObject private var state   = ClaudeHookNotificationState.shared
    @ObservedObject private var server  = AgentSocketServer.shared
    @State private var denyReason: String = ""
    @State private var showReasonField: Bool = false
    @State private var isDismissing: Bool = false
    @FocusState private var reasonFocused: Bool

    var body: some View {
        if state.isBlocked, let req = server.pendingPermission {
            permissionBanner(req)
        } else {
            doneBanner
        }
    }

    // MARK: - Done banner

    private var doneBanner: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                Text(state.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(.black).frame(width: 130)

            ClaudeStarLogo()
                .fill(.secondary)
                .frame(width: 11, height: 11)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Permission banner

    @ViewBuilder
    private func permissionBanner(_ req: PermissionRequest) -> some View {
        HStack(spacing: 0) {
            // Left: info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("\(req.cwdBasename) · \(req.toolName)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if !req.description.isEmpty {
                    Text(req.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if showReasonField {
                    TextField("拒绝原因…", text: $denyReason)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .focused($reasonFocused)
                        .onSubmit { submitDeny() }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Notch spacer
            Rectangle().fill(.black).frame(width: 130)

            // Right: action buttons
            HStack(spacing: 6) {
                // Allow
                Button {
                    server.allow()
                    dismiss()
                } label: {
                    Label("允许", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("允许此操作")

                // Deny / input reason
                if showReasonField {
                    Button {
                        submitDeny()
                    } label: {
                        Label("发送", systemImage: "return")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        withAnimation(.smooth(duration: 0.15)) {
                            showReasonField = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            reasonFocused = true
                        }
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("拒绝此操作（可输入原因）")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func submitDeny() {
        guard !isDismissing else { return }
        server.deny(reason: denyReason)
        dismiss()
    }

    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        denyReason = ""
        showReasonField = false
        // Set isBlocked = false first, then hide — both synchronously on MainActor
        // so didSet evaluates the correct state and doesn't restart the timer
        ClaudeHookNotificationState.shared.isBlocked = false
        withAnimation(.smooth) {
            BoringViewCoordinator.shared.expandingView.show = false
        }
    }
}

// MARK: - Claude Official Logo

/// Parses an SVG‑style path string into a SwiftUI `Path`.
private func pathFromSVG(_ d: String, in rect: CGRect) -> Path {
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

/// Claude's official logo — the iconic star mark from the dark SVG.
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
