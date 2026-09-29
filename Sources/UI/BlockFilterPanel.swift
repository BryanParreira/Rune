import AppKit
import RuneKit
import SwiftUI

/// "Filter Output…" on a block: its output lines that contain what you type, numbered, over
/// the pane. Long outputs stay readable without scrolling through everything.
final class BlockFilterModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    @Published var query = "" {
        didSet { refilter() }
    }
    @Published private(set) var matches: [Line] = []

    let command: String
    let palette: ChromePalette
    let onClose: () -> Void
    private let lines: [Line]

    /// Lines kept for filtering (the end of the output if it's longer).
    static let maxLines = 50_000

    init(command: String, output: String, palette: ChromePalette, onClose: @escaping () -> Void) {
        self.command = command
        self.palette = palette
        self.onClose = onClose
        let all = output.components(separatedBy: "\n")
        let offset = max(0, all.count - Self.maxLines)
        lines = all.suffix(Self.maxLines).enumerated().map { Line(id: offset + $0.offset + 1, text: $0.element) }
        refilter()
    }

    var totalLines: Int { lines.count }

    private func refilter() {
        let terms = query.split(separator: " ").map(String.init)
        matches = terms.isEmpty ? lines : lines.filter { line in
            terms.allSatisfy { line.text.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    func copyMatches() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(matches.map(\.text).joined(separator: "\n"), forType: .string)
    }
}

struct BlockFilterView: View {
    @ObservedObject var model: BlockFilterModel
    let fontSize: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        let p = model.palette
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(Color(nsColor: p.secondary))
                TextField("Filter the output of \(model.command)", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(Color(nsColor: p.text))
                    .focused($focused)
                    .onKeyPress(.escape) { model.onClose(); return .handled }
                Text("\(model.matches.count) of \(model.totalLines) lines")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(nsColor: p.hint))
                Button("Copy") { model.copyMatches() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(nsColor: p.accent))
                    .help("Copy the matching lines")
                Button { model.onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: p.hint)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (esc)")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1)
            if model.matches.isEmpty {
                Text("no lines contain “\(model.query)”")
                    .font(.hand(20))
                    .foregroundColor(Color(nsColor: p.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.matches) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(line.id)")
                                    .foregroundColor(Color(nsColor: p.hint))
                                    .frame(minWidth: 44, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text)
                                    .foregroundColor(Color(nsColor: p.text))
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: fontSize - 1, design: .monospaced))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: p.surface1))
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1) }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
