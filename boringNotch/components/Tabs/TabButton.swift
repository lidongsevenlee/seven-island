import SwiftUI

struct TabButton<IconView: View>: View {
    let label: String
    let icon: IconView
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            icon
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(label)
    }
}

#Preview {
    TabButton(label: "Music", icon: Image(systemName: "music.note"), selected: true) {
        print("Tapped")
    }
}
