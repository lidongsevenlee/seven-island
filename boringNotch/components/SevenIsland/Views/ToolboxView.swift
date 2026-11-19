import SwiftUI

struct ScreenColorSample: Equatable {
    let red: Int
    let green: Int
    let blue: Int

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        red = Self.byte(srgb.redComponent)
        green = Self.byte(srgb.greenComponent)
        blue = Self.byte(srgb.blueComponent)
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }

    var swatch: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    private static func byte(_ component: CGFloat) -> Int {
        Int((min(max(component, 0), 1) * 255).rounded())
    }
}

struct ToolboxView: View {
    private enum Tool: CaseIterable {
        case colorPicker

        var name: String {
            switch self {
            case .colorPicker: "取色器"
            }
        }
    }

    @State private var selectedTool: Tool = .colorPicker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        Button {
                            selectedTool = tool
                        } label: {
                            Text(tool.name)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(
                                    selectedTool == tool ? sevenIslandHoveredContentBackground : sevenIslandContentBackground,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedTool == tool ? .isSelected : [])
                    }
                }
            }
            .frame(height: 28)

            switch selectedTool {
            case .colorPicker:
                ScreenColorPickerView()
            }
        }
    }
}

private struct ScreenColorPickerView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @State private var copiedFormat: String?

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(vm.screenColorSample?.swatch ?? .white.opacity(0.08))
                .overlay {
                    if vm.screenColorSample == nil {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 23))
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .frame(width: 80, height: 76)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                valueRow("HEX", value: vm.screenColorSample?.hex)
                valueRow("RGB", value: vm.screenColorSample?.rgb)
            }
            .frame(maxWidth: 235)

            Spacer(minLength: 10)

            Button {
                copiedFormat = nil
                vm.pickScreenColor()
            } label: {
                Label(vm.isSamplingScreenColor ? "取色中…" : "屏幕取色", systemImage: "eyedropper")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(sevenIslandHoveredContentBackground, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(vm.isSamplingScreenColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(sevenIslandContentBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private func valueRow(_ format: String, value: String?) -> some View {
        Button {
            guard let value else { return }
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(value, forType: .string) {
                copiedFormat = format
            }
        } label: {
            HStack(spacing: 8) {
                Text(format)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
                Text(value ?? "—")
                    .monospaced()
                Spacer(minLength: 0)
                Image(systemName: copiedFormat == format ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制 \(format)")
        .accessibilityValue(value ?? "")
        .help(copiedFormat == format ? "已复制" : "复制 \(format)")
        .disabled(value == nil)
    }
}
