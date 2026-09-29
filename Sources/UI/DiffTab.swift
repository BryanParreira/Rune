import AppKit
import RuneKit
import SwiftUI

/// A file's changes since the last commit, in a tab: removed lines in red, added in green,
/// numbered in the old and new file. Read-only; it reloads when the file changes on disk.
final class DiffTab: TabContent {
    let id = UUID()
    let path: String
    let runningProgram: String? = nil
    private let model: DiffModel
    private let host: NSHostingView<DiffView>
    private var watcher: DirectoryWatcher?

    var title: String { (path as NSString).lastPathComponent + " · changes" }
    var contentView: NSView { host }

    init(path: String, repo: String, untracked: Bool, snapshot: ConfigSnapshot, onOpenFile: @escaping (String) -> Void) {
        self.path = path
        model = DiffModel(path: path, repo: repo, untracked: untracked, snapshot: snapshot)
        model.onOpenFile = onOpenFile
        host = NSHostingView(rootView: DiffView(model: model))
        host.safeAreaRegions = []
        model.reload()
        let folder = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        watcher = DirectoryWatcher(debounce: 0.4) { [weak self] in self?.model.reload() }
        watcher?.watch([folder])
    }

    func focus() {
        host.window?.makeFirstResponder(host)
    }

    func apply(_ snapshot: ConfigSnapshot) { model.apply(snapshot) }
    func closeContent() { watcher?.stop() }
}

final class DiffModel: ObservableObject {
    let path: String
    let repo: String
    /// Not tracked by git yet: the whole file is new.
    private(set) var untracked: Bool
    @Published private(set) var diff: GitDiff?
    @Published private(set) var loaded = false
    @Published private(set) var palette: ChromePalette
    @Published private(set) var font: NSFont
    var onOpenFile: (String) -> Void = { _ in }
    private var generation = 0

    init(path: String, repo: String, untracked: Bool, snapshot: ConfigSnapshot) {
        self.path = path
        self.repo = repo
        self.untracked = untracked
        palette = ChromePalette(theme: snapshot.theme)
        font = snapshot.font
    }

    var relativePath: String { String(path.dropFirst(repo.count).drop(while: { $0 == "/" })) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var isFolder: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func apply(_ snapshot: ConfigSnapshot) {
        palette = ChromePalette(theme: snapshot.theme)
        font = snapshot.font
    }

    func reload() {
        generation += 1
        let generation = generation
        let (path, repo, untracked) = (path, repo, untracked)
        guard !isFolder else {
            diff = nil
            loaded = true
            return
        }
        let searchPath = [ProcessInfo.processInfo.environment["PATH"] ?? "", CommandCatalog.shared.shellPath ?? ""].joined(separator: ":")
        DispatchQueue.global(qos: .userInitiated).async {
            var result = GitCommand.diff(of: path, in: repo, untracked: untracked, searchPath: searchPath)
            // Committed or added since the list was read: ask again the other way.
            var nowUntracked = untracked
            if result?.lines.isEmpty ?? true, FileManager.default.fileExists(atPath: path) {
                let tracked = GitCommand.run(["ls-files", "--error-unmatch", "--", path], in: repo, searchPath: searchPath)?.status == 0
                if tracked == untracked {
                    nowUntracked = !tracked
                    result = GitCommand.diff(of: path, in: repo, untracked: nowUntracked, searchPath: searchPath)
                }
            }
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.untracked = nowUntracked
                self.diff = result
                self.loaded = true
            }
        }
    }
}

struct DiffView: View {
    @ObservedObject var model: DiffModel

    var body: some View {
        let p = model.palette
        VStack(spacing: 0) {
            header
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff = model.diff, !diff.lines.isEmpty {
                lines(diff)
            } else {
                message
            }
        }
        .background(Color(nsColor: p.background))
    }

    private var header: some View {
        let p = model.palette
        return HStack(spacing: 12) {
            Image(systemName: "plusminus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(nsColor: p.ansiYellow))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: p.surface1)))
            VStack(alignment: .leading, spacing: 2) {
                Text((model.path as NSString).lastPathComponent)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Color(nsColor: p.text))
                    .lineLimit(1)
                Text(model.untracked ? "New file · not committed yet" : "Changes since the last commit · " + model.relativePath)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: p.hint))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 16)
            if let diff = model.diff {
                if diff.added > 0 { MetaChip(text: "+\(diff.added)", palette: p, color: p.success) }
                if diff.removed > 0 { MetaChip(text: "−\(diff.removed)", palette: p, color: p.error) }
                if diff.truncated { MetaChip(text: "first 20,000 lines", palette: p, color: p.ansiYellow) }
            }
            Rectangle().fill(Color(nsColor: p.outline)).frame(width: 1, height: 18).padding(.horizontal, 2)
            IconAction(symbol: "arrow.clockwise", help: "Refresh", palette: p) { model.reload() }
            if model.exists, !model.isFolder {
                IconAction(symbol: "doc.text", help: "Open the file in Rune", palette: p) { model.onOpenFile(model.path) }
            }
            IconAction(symbol: "doc.on.doc", help: "Copy path", palette: p) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.path, forType: .string)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1) }
    }

    private var message: some View {
        let p = model.palette
        let (title, detail): (String, String) = model.isFolder
            ? ("a new folder", "Its files aren't committed yet. Open it in the file list to look inside.")
            : model.diff == nil
                ? ("couldn't read the changes", "git didn't return a diff for this file.")
                : ("no changes", "This file matches the last commit.")
        return VStack(spacing: 6) {
            Text(title).font(.hand(24)).foregroundColor(Color(nsColor: p.secondary))
            Text(detail).font(.system(size: 12.5)).foregroundColor(Color(nsColor: p.hint))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lines(_ diff: GitDiff) -> some View {
        let p = model.palette
        let font = Font(model.font)
        let numberFont = Font(NSFont.monospacedDigitSystemFont(ofSize: max(9, model.font.pointSize - 2), weight: .regular))
        // Wide enough for the largest line number.
        let digits = String(diff.lines.compactMap { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0).count
        let numberWidth = CGFloat(max(3, digits)) * (model.font.pointSize * 0.62) + 8
        return GeometryReader { viewport in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.lines) { line in
                    if line.kind == .hunk {
                        HStack(spacing: 8) {
                            Image(systemName: "ellipsis").font(.system(size: 10)).foregroundColor(Color(nsColor: p.hint))
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11.5))
                                .foregroundColor(Color(nsColor: p.secondary))
                                .lineLimit(1)
                        }
                        .padding(.leading, numberWidth * 2 - 18)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: p.surface1))
                        .padding(.top, line.id == 0 ? 0 : 10)
                    } else {
                        HStack(spacing: 0) {
                            Text(line.oldNumber.map(String.init) ?? "").frame(width: numberWidth, alignment: .trailing)
                            Text(line.newNumber.map(String.init) ?? "").frame(width: numberWidth, alignment: .trailing)
                                .padding(.trailing, 10)
                        }
                        .font(numberFont)
                        .foregroundColor(Color(nsColor: p.hint))
                        .overlay(alignment: .leading) {
                            // Marker beside the numbers: + / − in the line's color.
                            Text(marker(line.kind))
                                .font(font)
                                .foregroundColor(Color(nsColor: color(line.kind, p)))
                                .offset(x: numberWidth * 2 + 2)
                        }
                        .modifier(LineText(text: line.kind == .note ? "(\(line.text))" : line.text, font: font,
                                           color: line.kind == .note ? p.hint : p.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: background(line.kind, p)))
                    }
                }
            }
            .padding(.bottom, 24)
            // Line colors span the whole width, not just the text.
            .frame(minWidth: viewport.size.width, alignment: .leading)
        }
        }
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        default: return ""
        }
    }

    private func color(_ kind: DiffLine.Kind, _ p: ChromePalette) -> NSColor {
        switch kind {
        case .added: return p.success
        case .removed: return p.error
        default: return p.hint
        }
    }

    private func background(_ kind: DiffLine.Kind, _ p: ChromePalette) -> NSColor {
        switch kind {
        case .added: return p.success.withAlphaComponent(p.isLight ? 0.13 : 0.16)
        case .removed: return p.error.withAlphaComponent(p.isLight ? 0.11 : 0.15)
        default: return .clear
        }
    }
}

/// The code part of a diff line, after the line numbers and the +/− marker.
private struct LineText: ViewModifier {
    let text: String
    let font: Font
    let color: NSColor

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            Text(text.isEmpty ? " " : text.replacingOccurrences(of: "\t", with: "    "))
                .font(font)
                .foregroundColor(Color(nsColor: color))
                .textSelection(.enabled)
                .fixedSize()
                .padding(.leading, 16)
                .padding(.vertical, 1)
        }
    }
}
