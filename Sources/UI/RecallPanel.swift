import AppKit
import RuneKit
import SwiftUI

/// Rune Recall: search everything run in Rune (commands and their output), on this Mac.
final class RecallModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results: [RecallStore.Entry] = []
    @Published var selection = 0
    @Published private(set) var hasSearched = false

    let palette: ChromePalette
    let onClose: () -> Void
    /// Puts a command in the focused terminal's input (never runs it).
    let onInsert: (String) -> Void
    /// Moves the focused terminal to a folder.
    let onOpenFolder: (String) -> Void
    private var pending: DispatchWorkItem?

    init(palette: ChromePalette, onClose: @escaping () -> Void, onInsert: @escaping (String) -> Void,
         onOpenFolder: @escaping (String) -> Void) {
        self.palette = palette
        self.onClose = onClose
        self.onInsert = onInsert
        self.onOpenFolder = onOpenFolder
        search()
    }

    var selected: RecallStore.Entry? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    private func scheduleSearch() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func search() {
        let query = query
        RecallService.shared.search(query) { [weak self] entries in
            guard let self, self.query == query else { return }
            self.results = entries
            self.selection = 0
            self.hasSearched = true
        }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
    }

    func insertSelected() {
        guard let entry = selected else { return }
        onClose()
        DispatchQueue.main.async { self.onInsert(entry.command) }
    }

    func copyOutput() {
        guard let entry = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.output, forType: .string)
    }

    func openFolder() {
        guard let entry = selected else { return }
        onClose()
        DispatchQueue.main.async { self.onOpenFolder(entry.directory) }
    }
}

struct RecallView: View {
    @ObservedObject var model: RecallModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let p = model.palette
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { model.onClose() }

            VStack(spacing: 0) {
                searchBar
                Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1)
                HStack(spacing: 0) {
                    list.frame(width: 320)
                    Rectangle().fill(Color(nsColor: p.outline)).frame(width: 1)
                    detail.frame(maxWidth: .infinity)
                }
                .frame(height: 420)
                Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1)
                footer
            }
            .frame(width: 860)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: p.surface1))
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(nsColor: p.outline), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 56)
        }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private var searchBar: some View {
        let p = model.palette
        return HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(nsColor: p.secondary))
            TextField("Search every command and its output…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(Color(nsColor: p.text))
                .focused($searchFocused)
                .onSubmit { model.insertSelected() }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.escape) { model.onClose(); return .handled }
            Label("On this Mac only", systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: p.hint))
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private var list: some View {
        let p = model.palette
        return Group {
            if model.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundColor(Color(nsColor: p.hint))
                    Text(model.query.isEmpty ? "nothing recalled yet —\nrun something and it shows up here" : "nothing matches “\(model.query)”")
                        .font(.hand(20))
                        .foregroundColor(Color(nsColor: p.secondary))
                        .multilineTextAlignment(.center)
                        .opacity(model.hasSearched ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                                RecallRow(entry: entry, isSelected: index == model.selection, palette: p)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selection = index }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.insertSelected() })
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, index in proxy.scrollTo(index) }
                }
            }
        }
    }

    private var detail: some View {
        let p = model.palette
        return Group {
            if let entry = model.selected {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.command)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(nsColor: p.text))
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Text(RecallRow.subtitle(for: entry))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(nsColor: entry.exitCode.map { $0 != 0 } == true ? p.error : p.hint))
                    ScrollView([.vertical, .horizontal]) {
                        Text(entry.output.isEmpty ? "(no output)" : Self.preview(entry.output))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(Color(nsColor: entry.output.isEmpty ? p.hint : p.text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: p.background)))
                }
                .padding(16)
            } else {
                Color.clear
            }
        }
    }

    private var footer: some View {
        let p = model.palette
        return HStack(spacing: 16) {
            hint("↑↓", "browse")
            hint("↵", "put in input")
            hint("esc", "close")
            Spacer()
            Button("Copy Output") { model.copyOutput() }
                .buttonStyle(.plain)
                .foregroundColor(Color(nsColor: p.accent))
                .disabled(model.selected == nil)
            Button("Go to Folder") { model.openFolder() }
                .buttonStyle(.plain)
                .foregroundColor(Color(nsColor: p.accent))
                .disabled(model.selected == nil)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(nsColor: model.palette.secondary))
            Text(label).font(.system(size: 11)).foregroundColor(Color(nsColor: model.palette.hint))
        }
    }

    /// Long outputs are trimmed for display (the full text is still copyable).
    static func preview(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 600 else { return output }
        return "… \(lines.count - 600) earlier lines\n" + lines.suffix(600).joined(separator: "\n")
    }
}

private struct RecallRow: View {
    let entry: RecallStore.Entry
    let isSelected: Bool
    let palette: ChromePalette

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func subtitle(for entry: RecallStore.Entry) -> String {
        var parts = [TabTitle.abbreviate(path: entry.directory, home: NSHomeDirectory()),
                     relative.localizedString(for: entry.date, relativeTo: Date())]
        if let code = entry.exitCode, code != 0 { parts.append("exit \(code)") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.command.components(separatedBy: .newlines).first ?? "")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(Color(nsColor: p.text))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(Self.subtitle(for: entry))
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: entry.exitCode.map { $0 != 0 } == true ? p.error : p.hint))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(nsColor: isSelected ? p.accent.withAlphaComponent(0.16) : .clear)))
    }
}
