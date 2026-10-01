import AppKit
import SwiftUI

/// The completion list that opens above the caret when Tab has several answers: subcommands
/// and flags with what they do, or files and folders. ↑↓ choose, Tab or Return insert, Esc
/// closes, and typing narrows it.
final class CompletionMenuModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: Int
        let name: String
        let detail: String?
        /// The text that replaces `range` when this item is picked.
        let insertion: String
    }

    @Published var items: [Item] = []
    @Published var selected = 0
    @Published var palette = ChromePalette(theme: .paper)
    @Published var fontSize: CGFloat = 13
    /// UTF-16 range in the editor that the picked item replaces.
    var range = NSRange(location: 0, length: 0)

    var isOpen: Bool { !items.isEmpty }

    static let visibleRows = 8

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    var rowHeight: CGFloat { ceil(fontSize + 10) }

    /// Rows shown: a window of `visibleRows` that follows the selection.
    var window: Range<Int> {
        let count = min(Self.visibleRows, items.count)
        let start = min(max(0, selected - count + 1), max(0, items.count - count))
        return start..<(start + count)
    }

    /// Wide enough for the longest name and a short description, within reason.
    var width: CGFloat {
        let charWidth = fontSize * 0.62
        let names = items.map(\.name.count).max() ?? 0
        let details = min(48, items.compactMap { $0.detail?.count }.max() ?? 0)
        return min(560, max(240, CGFloat(names + (details > 0 ? details + 4 : 0)) * charWidth + 40))
    }

    var height: CGFloat { CGFloat(window.count) * rowHeight + 8 + (items.count > Self.visibleRows ? 22 : 0) }
}

struct CompletionMenuView: View {
    @ObservedObject var model: CompletionMenuModel
    let onPick: (Int) -> Void

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.items[model.window]) { item in
                let isSelected = item.id == model.selected
                HStack(spacing: 14) {
                    Text(item.name)
                        .font(.system(size: model.fontSize - 0.5, design: .monospaced))
                        .foregroundColor(Color(nsColor: p.text))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let detail = item.detail {
                        Spacer(minLength: 8)
                        Text(detail)
                            .font(.system(size: model.fontSize - 2))
                            .foregroundColor(Color(nsColor: p.hint))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: model.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: isSelected ? p.highlight : .clear))
                )
                .contentShape(Rectangle())
                .onTapGesture { onPick(item.id) }
            }
            if model.items.count > CompletionMenuModel.visibleRows {
                Text("\(model.selected + 1) of \(model.items.count)  ·  keep typing to narrow")
                    .font(.system(size: max(9, model.fontSize - 3)))
                    .foregroundColor(Color(nsColor: p.hint))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
            }
        }
        .padding(4)
        .frame(width: model.width, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: p.surface1))
                .shadow(color: .black.opacity(p.isLight ? 0.12 : 0.35), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: p.outline), lineWidth: 1)
        )
    }
}
