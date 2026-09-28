import AppKit
import RuneKit
import SwiftUI

/// State for the left file tree: rooted at the active tab's working directory, folders load
/// lazily when expanded, and visible folders are watched so the tree stays current.
final class FileTreeModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let entry: FileListing.Entry
        let depth: Int
        var id: String { entry.path }
    }

    @Published private(set) var root: String?
    @Published var showHidden = false { didSet { reloadAll() } }
    @Published private(set) var rows: [Row] = []
    @Published var selection: String?

    private var children: [String: [FileListing.Entry]] = [:]
    private var expanded: Set<String> = []
    private var watcher: DirectoryWatcher?

    /// Actions provided by the window (they need the active session).
    var onInsertPath: (String) -> Void = { _ in }
    var onChangeDirectory: (String) -> Void = { _ in }
    var onNewTab: (String) -> Void = { _ in }

    var isActive = false {
        didSet { isActive ? reloadAll() : watcher?.stop() }
    }

    func setRoot(_ path: String) {
        guard path != root else { return }
        root = path
        expanded.removeAll()
        children.removeAll()
        selection = nil
        if isActive { reloadAll() }
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    func toggle(_ entry: FileListing.Entry) {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
            rebuildRows()
            watchVisibleFolders()
        } else {
            expanded.insert(entry.path)
            load(entry.path)
        }
    }

    func collapseAll() {
        expanded.removeAll()
        rebuildRows()
        watchVisibleFolders()
    }

    func reloadAll() {
        guard let root, isActive else { return }
        let folders = [root] + expanded.sorted()
        let showHidden = showHidden
        DispatchQueue.global(qos: .userInitiated).async {
            var loaded: [String: [FileListing.Entry]] = [:]
            for folder in folders { loaded[folder] = FileListing.entries(at: folder, showHidden: showHidden) }
            DispatchQueue.main.async {
                guard self.root == root else { return }
                self.children = loaded
                self.expanded = self.expanded.filter { loaded[$0] != nil }
                self.rebuildRows()
                self.watchVisibleFolders()
            }
        }
    }

    private func load(_ folder: String) {
        let showHidden = showHidden
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = FileListing.entries(at: folder, showHidden: showHidden)
            DispatchQueue.main.async {
                self.children[folder] = entries
                self.rebuildRows()
                self.watchVisibleFolders()
            }
        }
    }

    private func rebuildRows() {
        guard let root else { rows = []; return }
        var result: [Row] = []
        func walk(_ folder: String, depth: Int) {
            for entry in children[folder] ?? [] {
                result.append(Row(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) {
                    walk(entry.path, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        rows = result
    }

    private func watchVisibleFolders() {
        guard isActive, let root else { return }
        if watcher == nil {
            watcher = DirectoryWatcher(debounce: 0.3) { [weak self] in self?.reloadAll() }
        }
        let folders = ([root] + expanded.sorted()).prefix(64).map { URL(fileURLWithPath: $0, isDirectory: true) }
        watcher?.watch(Array(folders))
    }

    // MARK: Actions

    func open(_ entry: FileListing.Entry) {
        if entry.isDirectory {
            toggle(entry)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
        }
    }

    func copyPath(_ entry: FileListing.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
    }

    func reveal(_ entry: FileListing.Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }
}

struct FileTreeView: View {
    @ObservedObject var model: FileTreeModel
    let palette: ChromePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color(nsColor: palette.outline)).frame(height: 1)
            if model.rows.isEmpty {
                Text(model.root == nil ? "No folder" : "Empty folder")
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: palette.hint))
                    .padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            FileRow(row: row, model: model, palette: palette)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: palette.background))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: palette.outline)).frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.root.map { ($0 as NSString).lastPathComponent }.map { $0.isEmpty ? "/" : $0 } ?? "Files")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(nsColor: palette.text))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.root ?? "")
            Spacer(minLength: 4)
            HeaderButton(symbol: model.showHidden ? "eye" : "eye.slash", help: model.showHidden ? "Hide hidden files" : "Show hidden files", palette: palette) {
                model.showHidden.toggle()
            }
            HeaderButton(symbol: "arrow.clockwise", help: "Refresh", palette: palette) { model.reloadAll() }
            HeaderButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Collapse all", palette: palette) { model.collapseAll() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 34)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let palette: ChromePalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: hovering ? palette.text : palette.secondary))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: hovering ? palette.surface2 : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct FileRow: View {
    let row: FileTreeModel.Row
    @ObservedObject var model: FileTreeModel
    let palette: ChromePalette
    @State private var hovering = false

    var body: some View {
        let entry = row.entry
        let selected = model.selection == entry.path
        HStack(spacing: 5) {
            Group {
                if entry.isDirectory {
                    Image(systemName: model.isExpanded(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color(nsColor: palette.hint))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            Image(systemName: FileIcon.symbol(for: entry, expanded: model.isExpanded(entry.path)))
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: entry.isDirectory ? palette.accent.withAlphaComponent(0.85) : palette.secondary))
                .frame(width: 16)
            Text(entry.name)
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: entry.isHidden ? palette.secondary : palette.text))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: selected ? palette.accent.withAlphaComponent(0.22) : (hovering ? palette.surface1 : .clear)))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !entry.isDirectory { model.open(entry) } }
        .simultaneousGesture(TapGesture().onEnded {
            model.selection = entry.path
            if entry.isDirectory { model.toggle(entry) }
        })
        .help(entry.path)
        .contextMenu {
            if entry.isDirectory {
                Button("cd Into Folder") { model.onChangeDirectory(entry.path) }
                Button("New Tab Here") { model.onNewTab(entry.path) }
            } else {
                Button("Open") { model.open(entry) }
            }
            Button("Insert Path in Input") { model.onInsertPath(entry.path) }
            Divider()
            Button("Copy Path") { model.copyPath(entry) }
            Button("Reveal in Finder") { model.reveal(entry) }
        }
    }
}

enum FileIcon {
    static func symbol(for entry: FileListing.Entry, expanded: Bool) -> String {
        if entry.isDirectory { return expanded ? "folder.fill" : "folder" }
        switch entry.fileExtension {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "icns": return "photo"
        case "sh", "zsh", "bash", "fish", "command": return "terminal"
        case "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "m", "cpp", "java", "kt", "html", "css": return "chevron.left.forwardslash.chevron.right"
        case "zip", "gz", "tar", "dmg", "xz", "7z": return "archivebox"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "mp3", "wav", "m4a": return "play.rectangle"
        default: return entry.name.hasPrefix(".") ? "gearshape" : "doc"
        }
    }
}
