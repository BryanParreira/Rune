import AppKit
import SwiftUI

/// Above the input while a login command reached a shell prompt: "Use Rune's input on host?"
/// Also says so when setting it up didn't work (that session stays a plain terminal).
final class RemoteOfferModel: ObservableObject {
    enum Kind: Equatable { case offer(String), failed(String) }
    @Published var kind: Kind?
    @Published var palette = ChromePalette(theme: .paper)
    @Published var horizontalPadding: CGFloat = 16

    var onEnable: (_ always: Bool) -> Void = { _ in }
    var onDecline: () -> Void = {}
}

struct RemoteOfferBar: View {
    @ObservedObject var model: RemoteOfferModel

    var body: some View {
        let p = model.palette
        Group {
            switch model.kind {
            case .offer(let host):
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .foregroundColor(Color(nsColor: p.accent))
                    Text("Use Rune's input on \(host)?")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(nsColor: p.text))
                    Text("Blocks, suggestions and ⌘↵ AI, like here. Rune types a short setup into this session; nothing is saved on the server.")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(nsColor: p.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    button("Enable", prominent: true) { model.onEnable(false) }
                    button("Always for this host", prominent: false) { model.onEnable(true) }
                    button("Not now", prominent: false) { model.onDecline() }
                }
            case .failed(let host):
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundColor(Color(nsColor: p.hint))
                    Text("Rune's input isn't available on \(host) (its shell isn't bash or zsh). Keys go straight to the session.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: p.secondary))
                    Spacer()
                    button("OK", prominent: false) { model.onDecline() }
                }
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, model.horizontalPadding)
        .padding(.vertical, model.kind == nil ? 0 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: model.kind == nil ? .clear : p.surface1))
        .overlay(alignment: .top) {
            if model.kind != nil { Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1) }
        }
    }

    private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let p = model.palette
        return Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: prominent ? p.onAccent : p.text))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: prominent ? p.accent : p.surface3)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
