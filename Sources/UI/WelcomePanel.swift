import SwiftUI

final class WelcomeModel: ObservableObject {
    @Published var palette = ChromePalette(theme: .runeDark)
    @Published var fontSize: CGFloat = 13
    @Published var horizontalPadding: CGFloat = 16

    var onDismiss: () -> Void = {}
    var onNeverShow: () -> Void = {}
}

/// "New session" panel shown above the input editor in fresh tabs.
struct WelcomePanel: View {
    @ObservedObject var model: WelcomeModel

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: [String]
        let text: String
    }

    private let shortcuts = [
        Shortcut(keys: ["↑"], text: "cycle past commands"),
        Shortcut(keys: ["⇧", "↵"], text: "add a new line to your command"),
        Shortcut(keys: ["⇥"], text: "complete files and folders"),
        Shortcut(keys: ["⌘", "↑"], text: "select and jump between blocks"),
        Shortcut(keys: ["⌘", "↵"], text: "ask AI (runs on your Mac)"),
        Shortcut(keys: ["⌘", "B"], text: "show files and folders"),
        Shortcut(keys: ["⌘", ","], text: "open settings"),
    ]

    var body: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: model.fontSize + 11, height: model.fontSize + 11)
                Text("New session")
                    .font(.system(size: model.fontSize + 5, weight: .semibold))
                    .foregroundColor(Color(nsColor: palette.text))
                Spacer()
                Button(action: model.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: palette.hint))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide for this tab")
            }
            .padding(.bottom, 12)

            ForEach(shortcuts) { shortcut in
                HStack(spacing: 7) {
                    HStack(spacing: 3) {
                        ForEach(shortcut.keys, id: \.self) { key in
                            Keycap(key: key, size: model.fontSize - 2, palette: palette)
                        }
                    }
                    Text(shortcut.text)
                        .font(.system(size: model.fontSize - 1))
                        .foregroundColor(Color(nsColor: palette.secondary))
                }
                .padding(.bottom, 7)
            }

            HStack {
                Spacer()
                Button("Don't show again", action: model.onNeverShow)
                    .buttonStyle(.plain)
                    .font(.system(size: max(9, model.fontSize - 3)))
                    .foregroundColor(Color(nsColor: palette.hint))
            }
        }
        .padding(.horizontal, model.horizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.background))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: palette.outline)).frame(height: 1)
        }
    }
}

/// Square key label, sized from the terminal font.
struct Keycap: View {
    let key: String
    let size: CGFloat
    let palette: ChromePalette

    var body: some View {
        Text(key)
            .font(.system(size: size - 1, weight: .medium))
            .foregroundColor(Color(nsColor: palette.text))
            .frame(minWidth: size + 5, minHeight: size + 5)
            .padding(.horizontal, key.count > 1 ? 3 : 0)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: palette.surface3))
            )
    }
}
