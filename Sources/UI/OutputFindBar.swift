import AppKit
import RuneKit
import SwiftUI

/// ⌘F in a terminal pane: a bar over the output with a match count, arrows to step through
/// matches (newest first), Match Case, and a switch to search only the selected block.
/// Matches are marked in the output by the block overlay.
final class OutputFindModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch(delay: 0.06) } } }
    @Published var caseSensitive = false { didSet { search() } }
    /// The query is a regular expression.
    @Published var useRegex = false { didSet { search() } }
    /// Regex on, and the query isn't a valid pattern.
    var invalidPattern: Bool { useRegex && !query.isEmpty && !OutputSearch.isValidPattern(query) }
    @Published var inSelectedBlock = false { didSet { search() } }
    @Published private(set) var matches: [OutputSearch.Match] = []
    @Published private(set) var current: Int?
    @Published var palette = ChromePalette(theme: .paper)
    @Published private(set) var isOpen = false
    /// Bumped to move keyboard focus into the field.
    @Published private(set) var focusRequest = 0
    @Published private(set) var hasSelectedBlock = false

    /// Rows to search (scroll-invariant row, text); set by the session.
    var rows: (_ selectedBlockOnly: Bool) -> [(row: Int, text: String)] = { _ in [] }
    var selectedBlockExists: () -> Bool = { false }
    var onReveal: (OutputSearch.Match) -> Void = { _ in }
    var onChange: () -> Void = {}
    var onClose: () -> Void = {}
    private var pending: DispatchWorkItem?

    func open() {
        hasSelectedBlock = selectedBlockExists()
        if !hasSelectedBlock { inSelectedBlock = false }
        isOpen = true
        focusRequest += 1
        search()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        pending?.cancel()
        matches = []
        current = nil
        onChange()
        onClose()
    }

    /// New output arrived: search again shortly (keeping the place).
    func outputChanged() {
        guard isOpen, !query.isEmpty else { return }
        scheduleSearch(delay: 0.3)
    }

    private func scheduleSearch(delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func search() {
        guard isOpen else { return }
        let previous = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        matches = OutputSearch.find(query, in: rows(inSelectedBlock), caseSensitive: caseSensitive, regex: useRegex)
        if matches.isEmpty {
            current = nil
        } else if let previous, let same = matches.firstIndex(where: { $0.row == previous.row && $0.column == previous.column }) {
            current = same
        } else {
            // Start from the newest output, where you probably are.
            current = matches.count - 1
            onReveal(matches[matches.count - 1])
        }
        onChange()
    }

    /// Return / ⌘G: the match above (older output). ⇧: the one below.
    func step(older: Bool) {
        guard !matches.isEmpty else { return NSSound.beep() }
        let index = current ?? matches.count - 1
        current = older ? (index - 1 + matches.count) % matches.count : (index + 1) % matches.count
        if let current { onReveal(matches[current]) }
        onChange()
    }
}

struct OutputFindBar: View {
    @ObservedObject var model: OutputFindModel
    @FocusState private var focused: Bool

    var body: some View {
        let p = model.palette
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: p.hint))
            TextField("Find in output", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(Color(nsColor: p.text))
                .focused($focused)
                .onKeyPress(.escape) { model.close(); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    model.step(older: !press.modifiers.contains(.shift))
                    return .handled
                }
            Text(countText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: model.query.isEmpty || !model.matches.isEmpty ? p.hint : p.error))
                .fixedSize()
            toggle("Aa", on: model.caseSensitive, help: "Match case") { model.caseSensitive.toggle() }
            toggle(".*", on: model.useRegex, help: "Regular expression") { model.useRegex.toggle() }
            if model.hasSelectedBlock {
                toggle("Block", on: model.inSelectedBlock, help: "Only the selected block") { model.inSelectedBlock.toggle() }
            }
            arrow("chevron.up", help: "Previous match (↵, ⌘G)") { model.step(older: true) }
            arrow("chevron.down", help: "Next match (⇧↵, ⇧⌘G)") { model.step(older: false) }
            arrow("xmark", help: "Close (esc)") { model.close() }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: p.surface1))
                .shadow(color: .black.opacity(p.isLight ? 0.12 : 0.35), radius: 8, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(nsColor: p.outline), lineWidth: 1))
        .onChange(of: model.focusRequest) { _, _ in focused = true }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var countText: String {
        if model.query.isEmpty { return "" }
        if model.invalidPattern { return "invalid pattern" }
        guard let current = model.current, !model.matches.isEmpty else { return "no matches" }
        let total = model.matches.count >= 10_000 ? "10,000+" : model.matches.count.formatted()
        return "\(current + 1) of \(total)"
    }

    private func toggle(_ title: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        let p = model.palette
        return Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(nsColor: on ? p.text : p.hint))
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(nsColor: on ? p.surface3 : .clear)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func arrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: model.palette.secondary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
