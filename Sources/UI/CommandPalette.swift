import AppKit
import RuneKit
import SwiftUI

/// One thing the command palette can do.
struct PaletteItem: Identifiable {
    enum Kind: String {
        case action = "Action"
        case workflow = "Workflow"
        case tab = "Tab"
        case folder = "Folder"
        case history = "History"
        case theme = "Theme"
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    let symbol: String
    var shortcut: String?
    /// Extra words to match on (not shown).
    var keywords = ""
    let run: () -> Void
}

final class PaletteModel: ObservableObject {
    @Published var query = "" {
        didSet { refilter() }
    }
    @Published private(set) var results: [PaletteItem] = []
    @Published var selection = 0

    let palette: ChromePalette
    private let items: [PaletteItem]
    private let onClose: () -> Void

    /// Shown before anything is typed, in this order.
    private static let browseKinds: [PaletteItem.Kind] = [.workflow, .action, .tab, .folder]
    private static let limit = 60

    init(items: [PaletteItem], palette: ChromePalette, onClose: @escaping () -> Void) {
        self.items = items
        self.palette = palette
        self.onClose = onClose
        refilter()
    }

    private func refilter() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = Self.browseKinds.flatMap { kind in items.filter { $0.kind == kind } }
        } else {
            results = items
                .compactMap { item -> (PaletteItem, Int)? in
                    // History is long and noisy: every typed word must appear as written.
                    if item.kind == .history, !Self.containsWords(of: trimmed, in: item.title) { return nil }
                    let titleScore = FuzzyMatch.score(trimmed, in: item.title).map { $0 + 40 }
                    let extraScore = FuzzyMatch.score(trimmed, in: item.keywords + " " + (item.subtitle ?? ""))
                    guard let score = [titleScore, extraScore].compactMap({ $0 }).max() else { return nil }
                    return (item, score + Self.kindBoost(item.kind))
                }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.limit)
                .map(\.0)
        }
        selection = 0
    }

    private static func containsWords(of query: String, in text: String) -> Bool {
        query.split(separator: " ").allSatisfy { text.range(of: $0, options: [.caseInsensitive]) != nil }
    }

    /// Actions and workflows rank above the (much longer) history list on equal matches.
    private static func kindBoost(_ kind: PaletteItem.Kind) -> Int {
        switch kind {
        case .action, .workflow: return 30
        case .tab, .theme: return 20
        case .folder: return 10
        case .history: return 0
        }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func runSelected() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    func run(_ item: PaletteItem) {
        close()
        // After the palette is gone, so focus changes made by the item stick.
        DispatchQueue.main.async { item.run() }
    }

    func close() {
        onClose()
    }
}

struct CommandPaletteView: View {
    @ObservedObject var model: PaletteModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let p = model.palette
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { model.close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(nsColor: p.secondary))
                    TextField("Search actions, workflows, tabs, folders and history", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundColor(Color(nsColor: p.text))
                        .focused($searchFocused)
                        .onSubmit { model.runSelected() }
                        .onKeyPress(.upArrow) { model.move(-1); return .handled }
                        .onKeyPress(.downArrow) { model.move(1); return .handled }
                        .onKeyPress(.escape) { model.close(); return .handled }
                        .onKeyPress(keys: ["p", "n"], phases: .down) { press in
                            // ⌃P / ⌃N like the shell.
                            guard press.modifiers == .control else { return .ignored }
                            model.move(press.key == "p" ? -1 : 1)
                            return .handled
                        }
                }
                .padding(.horizontal, 16)
                .frame(height: 50)

                Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1)

                if model.results.isEmpty {
                    Text("no matches — try fewer letters")
                        .font(.hand(20))
                        .foregroundColor(Color(nsColor: p.hint))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                    PaletteRow(item: item, isSelected: index == model.selection, palette: p)
                                        .id(index)
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.run(item) }
                                        .onHover { if $0 { model.selection = index } }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: model.selection) { _, index in
                            proxy.scrollTo(index)
                        }
                    }
                }

                Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1)
                HStack(spacing: 16) {
                    hint("↑↓", "navigate")
                    hint("↵", "run")
                    hint("esc", "close")
                    Spacer()
                    Text("\(model.results.count) result\(model.results.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: p.hint))
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
            }
            .frame(width: 640)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: p.surface1))
                    .shadow(color: .black.opacity(p.isLight ? 0.18 : 0.45), radius: 30, y: 16)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(nsColor: p.outline), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 64)
        }
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(nsColor: model.palette.secondary))
            Text(label).font(.system(size: 11)).foregroundColor(Color(nsColor: model.palette.hint))
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    let palette: ChromePalette

    var body: some View {
        let p = palette
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Color(nsColor: isSelected ? p.text : p.secondary))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: p.foreground.withAlphaComponent(isSelected ? 0.1 : 0.05))))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(Color(nsColor: p.text))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, design: item.kind == .workflow || item.kind == .history ? .monospaced : .default))
                        .foregroundColor(Color(nsColor: p.hint))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color(nsColor: p.secondary))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: p.foreground.withAlphaComponent(0.07))))
            } else {
                Text(item.kind.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: p.hint))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: item.subtitle == nil ? 38 : 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: isSelected ? p.accent.withAlphaComponent(0.16) : .clear))
        )
    }
}
