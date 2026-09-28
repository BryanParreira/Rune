import AppKit
import RuneKit
import SwiftUI

/// State for the left file tree: rooted at the active tab's working directory, folders load
/// lazily when expanded, visible folders are watched, and git status colors changed files.
final class FileTreeModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let entry: FileListing.Entry
        let depth: Int
        /// Path relative to the root (shown for filter results).
        var relativePath: String?
        var id: String { entry.path }
    }

    @Published private(set) var root: String?
    @Published var showHidden = false { didSet { reloadAll() } }
    @Published private(set) var rows: [Row] = []
    @Published var selection: String?
    @Published private(set) var git = GitStatusSnapshot()
    @Published var filter = "" { didSet { runFilter() } }
    @Published private(set) var filterResults: [Row] = []
    @Published private(set) var isFiltering = false

    private var children: [String: [FileListing.Entry]] = [:]
    private var expanded: Set<String> = []
    private var watcher: DirectoryWatcher?
    private var filterWork: DispatchWorkItem?

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
        filter = ""
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
        refreshGitStatus()
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

    // MARK: Git

    private func refreshGitStatus() {
        guard let root, let repo = GitInfo.repositoryRoot(for: root) else {
            git = GitStatusSnapshot()
            return
        }
        let path = [ProcessInfo.processInfo.environment["PATH"] ?? "", CommandCatalog.shared.shellPath ?? ""].joined(separator: ":")
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let git = path.split(separator: ":").map { String($0) + "/git" }.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-C", repo, "status", "--porcelain=v1", "-z"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
            let snapshot = GitStatusSnapshot.parse(porcelain: data, repoRoot: repo)
            DispatchQueue.main.async {
                if self.root.flatMap({ GitInfo.repositoryRoot(for: $0) }) == repo { self.git = snapshot }
            }
        }
    }

    // MARK: Filter

    /// Searches file names under the root (skipping build/dependency folders), off the main thread.
    private func runFilter() {
        filterWork?.cancel()
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let root else {
            filterResults = []
            isFiltering = false
            return
        }
        isFiltering = true
        let showHidden = showHidden
        let work = DispatchWorkItem { [weak self] in
            let results = Self.search(root: root, query: query, showHidden: showHidden)
            DispatchQueue.main.async {
                guard let self, self.filter.trimmingCharacters(in: .whitespaces) == query else { return }
                self.filterResults = results
                self.isFiltering = false
            }
        }
        filterWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    static let skippedFolders: Set<String> = ["node_modules", ".git", "build", "DerivedData", ".build", "Pods", "dist", "target", ".venv", "venv", "__pycache__"]

    static func search(root: String, query: String, showHidden: Bool, limit: Int = 300) -> [Row] {
        var results: [Row] = []
        var queue: [(String, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, results.count < limit, visited < 20_000 {
            let (folder, depth) = queue.removeFirst()
            for entry in FileListing.entries(at: folder, showHidden: showHidden) {
                visited += 1
                if entry.name.localizedCaseInsensitiveContains(query) {
                    let relative = String(entry.path.dropFirst(root.count).drop(while: { $0 == "/" }))
                    results.append(Row(entry: entry, depth: 0, relativePath: relative))
                }
                if entry.isDirectory, depth < 10, !skippedFolders.contains(entry.name), !entry.isSymlink {
                    queue.append((entry.path, depth + 1))
                }
            }
        }
        return results
    }

    // MARK: Actions

    func open(_ entry: FileListing.Entry) {
        guard !entry.isDirectory else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
    }

    func copyPath(_ entry: FileListing.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
    }

    func reveal(_ entry: FileListing.Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }
}

// MARK: - View

struct FileTreeView: View {
    @ObservedObject var model: FileTreeModel
    let palette: ChromePalette
    var onResize: (CGFloat) -> Void = { _ in }
    var onResizeEnded: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            FilterField(text: $model.filter, palette: palette)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            content
        }
        .background(Color(nsColor: palette.background))
        .overlay(alignment: .trailing) { ResizeHandle(palette: palette, onResize: onResize, onEnded: onResizeEnded) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: palette.ansiBlue))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.root.map { ($0 as NSString).lastPathComponent }.map { $0.isEmpty ? "/" : $0 } ?? "Files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(nsColor: palette.text))
                    .lineLimit(1)
                Text(model.root.map { TabTitle.abbreviate(path: ($0 as NSString).deletingLastPathComponent, home: NSHomeDirectory()) } ?? "")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: palette.hint))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(model.root ?? "")
            Spacer(minLength: 4)
            HeaderButton(symbol: model.showHidden ? "eye" : "eye.slash", help: model.showHidden ? "Hide hidden files" : "Show hidden files", palette: palette) {
                model.showHidden.toggle()
            }
            HeaderButton(symbol: "arrow.clockwise", help: "Refresh", palette: palette) { model.reloadAll() }
            HeaderButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Collapse folders", palette: palette) { model.collapseAll() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 48)
    }

    @ViewBuilder
    private var content: some View {
        let filtering = !model.filter.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = filtering ? model.filterResults : model.rows
        if rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if filtering && model.isFiltering {
                    ProgressView().controlSize(.small)
                } else {
                    Text(filtering ? "No files match “\(model.filter)”" : (model.root == nil ? "No folder" : "This folder is empty"))
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: palette.hint))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        FileRow(row: row, model: model, palette: palette)
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }
}

private struct FilterField: View {
    @Binding var text: String
    let palette: ChromePalette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: palette.hint))
            TextField("Filter files", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: palette.text))
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(Color(nsColor: palette.hint))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: palette.surface1)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: focused ? palette.accent.withAlphaComponent(0.6) : palette.outline), lineWidth: 1)
        )
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
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: hovering ? palette.surface2 : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Thin draggable strip on the sidebar's right edge (also its border line).
private struct ResizeHandle: View {
    let palette: ChromePalette
    let onResize: (CGFloat) -> Void
    let onEnded: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: hovering || dragging ? palette.accent.withAlphaComponent(0.6) : palette.outline))
                .frame(width: hovering || dragging ? 2 : 1)
        }
        .frame(width: 6)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    onResize(value.location.x)
                }
                .onEnded { _ in
                    dragging = false
                    onEnded()
                }
        )
    }
}

private struct FileRow: View {
    let row: FileTreeModel.Row
    @ObservedObject var model: FileTreeModel
    let palette: ChromePalette
    @State private var hovering = false

    private static let indent: CGFloat = 14
    private static let leading: CGFloat = 12

    var body: some View {
        let entry = row.entry
        let selected = model.selection == entry.path
        let gitState = model.git.state(for: entry.path)
        HStack(spacing: 6) {
            Group {
                if entry.isDirectory && row.relativePath == nil {
                    Image(systemName: model.isExpanded(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(nsColor: palette.hint))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            Image(systemName: FileIcon.symbol(for: entry, expanded: model.isExpanded(entry.path)))
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: FileIcon.color(for: entry, palette: palette)))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name)
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: nameColor(gitState, hidden: entry.isHidden)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let relative = row.relativePath, relative != entry.name {
                    Text((relative as NSString).deletingLastPathComponent)
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: palette.hint))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let gitState, !gitState.badge.isEmpty {
                if entry.isDirectory {
                    Circle().fill(Color(nsColor: gitColor(gitState))).frame(width: 5, height: 5)
                } else {
                    Text(gitState.badge)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(nsColor: gitColor(gitState)))
                }
            }
        }
        .padding(.leading, Self.leading + CGFloat(row.depth) * Self.indent)
        .padding(.trailing, 12)
        .frame(height: row.relativePath == nil ? 26 : 34)
        .background(alignment: .leading) { indentGuides }
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: selected ? palette.accent.withAlphaComponent(0.2) : (hovering ? palette.surface1 : .clear)))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !entry.isDirectory { model.open(entry) } }
        .simultaneousGesture(TapGesture().onEnded {
            model.selection = entry.path
            if entry.isDirectory && row.relativePath == nil { model.toggle(entry) }
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

    /// Faint vertical lines marking each nesting level.
    private var indentGuides: some View {
        HStack(spacing: 0) {
            ForEach(0..<row.depth, id: \.self) { level in
                Rectangle()
                    .fill(Color(nsColor: palette.outline))
                    .frame(width: 1)
                    .padding(.leading, level == 0 ? Self.leading + 4.5 : Self.indent - 1)
            }
        }
    }

    private func gitColor(_ state: GitFileState) -> NSColor {
        switch state {
        case .modified, .renamed: return palette.ansiYellow
        case .added, .untracked: return palette.success
        case .deleted, .conflicted: return palette.error
        case .ignored: return palette.hint
        }
    }

    private func nameColor(_ state: GitFileState?, hidden: Bool) -> NSColor {
        if let state, state != .ignored { return gitColor(state).blended(withFraction: 0.25, of: palette.foreground) ?? gitColor(state) }
        return hidden ? palette.secondary : palette.text
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
        case "lock": return "lock"
        default:
            if entry.name == "Makefile" || entry.name == "Dockerfile" { return "hammer" }
            return entry.name.hasPrefix(".") ? "gearshape" : "doc"
        }
    }

    static func color(for entry: FileListing.Entry, palette: ChromePalette) -> NSColor {
        if entry.isDirectory { return palette.ansiBlue.withAlphaComponent(0.9) }
        switch entry.fileExtension {
        case "swift": return NSColor(srgbRed: 0.94, green: 0.44, blue: 0.27, alpha: 1)
        case "js", "jsx", "json": return palette.ansiYellow
        case "ts", "tsx", "go": return palette.ansiBlue
        case "py": return NSColor(srgbRed: 0.35, green: 0.62, blue: 0.9, alpha: 1)
        case "rs", "html": return NSColor(srgbRed: 0.87, green: 0.52, blue: 0.35, alpha: 1)
        case "md", "markdown", "txt": return palette.secondary
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "icns": return palette.ansiMagenta
        case "sh", "zsh", "bash", "fish", "command": return palette.success
        case "yml", "yaml", "toml", "plist", "xml": return palette.ansiCyan
        default: return palette.secondary
        }
    }
}
