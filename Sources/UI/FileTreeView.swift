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
    private var gitRunning = false
    private var gitRequestedAgain = false
    private var lastGitRun = Date.distantPast

    /// Actions provided by the window (they need the active session).
    var onInsertPath: (String) -> Void = { _ in }
    var onChangeDirectory: (String) -> Void = { _ in }
    var onNewTab: (String) -> Void = { _ in }
    /// Opens a file in a Rune tab; `pinned` false reuses the preview tab.
    var onOpenFile: (String, Bool) -> Void = { _, _ in }
    @Published private(set) var branch: String?

    /// What the sidebar lists: the folder's files, or the repository's changed files.
    enum Section: String { case files, changes }
    @Published var section: Section = .files {
        didSet { updateChangesTimer() }
    }
    /// While the Changes list shows, git status is re-read every few seconds: edits deep in
    /// the repository aren't seen by the folder watcher.
    private var changesTimer: Timer?

    private func updateChangesTimer() {
        let wanted = isActive && section == .changes
        if wanted, changesTimer == nil {
            refreshGitStatus()
            changesTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshGitStatus() }
        } else if !wanted {
            changesTimer?.invalidate()
            changesTimer = nil
        }
    }
    /// Top level of the repository the root is in.
    @Published private(set) var repoRoot: String?
    /// Added/removed lines per changed file (since the last commit).
    @Published private(set) var lineCounts: [String: LineCounts] = [:]
    /// Opens the changes of a file in a diff tab: (path, repository, untracked).
    var onOpenDiff: (String, String, Bool) -> Void = { _, _, _ in }

    struct Change: Identifiable, Equatable {
        let path: String
        let state: GitFileState
        /// Path inside the repository.
        let relativePath: String
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var isFolder: Bool { relativePath.hasSuffix("/") }
    }

    /// Changed files, by path; filtered like the file list.
    var changes: [Change] {
        guard let repoRoot else { return [] }
        let query = filter.trimmingCharacters(in: .whitespaces)
        var isDirectory: ObjCBool = false
        return git.files.map { path, state in
            var relative = String(path.dropFirst(repoRoot.count).drop(while: { $0 == "/" }))
            if state == .untracked, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { relative += "/" }
            return Change(path: path, state: state, relativePath: relative)
        }
        .filter { query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query) }
        .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    var isActive = false {
        didSet {
            isActive ? reloadAll() : watcher?.stop()
            updateChangesTimer()
        }
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

    /// Runs `git status` at most every 2 s, never concurrently (busy repos change constantly).
    private func refreshGitStatus() {
        guard let root, let repo = GitInfo.repositoryRoot(for: root) else {
            git = GitStatusSnapshot()
            branch = nil
            repoRoot = nil
            lineCounts = [:]
            section = .files
            return
        }
        if gitRunning { gitRequestedAgain = true; return }
        let wait = 2 - Date().timeIntervalSince(lastGitRun)
        if wait > 0 {
            gitRunning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.gitRunning = false
                self?.refreshGitStatus()
            }
            return
        }
        gitRunning = true
        lastGitRun = Date()
        let path = [ProcessInfo.processInfo.environment["PATH"] ?? "", CommandCatalog.shared.shellPath ?? ""].joined(separator: ":")
        DispatchQueue.global(qos: .utility).async {
            var snapshot: GitStatusSnapshot?
            if let status = GitCommand.run(["status", "--porcelain=v1", "-z"], in: repo, searchPath: path), status.status == 0 {
                snapshot = GitStatusSnapshot.parse(porcelain: status.output, repoRoot: repo)
            }
            var counts: [String: LineCounts] = [:]
            if snapshot?.changedFileCount ?? 0 > 0,
               let numstat = GitCommand.run(["diff", "HEAD", "--numstat", "--no-color", "--no-ext-diff", "--no-textconv"], in: repo, searchPath: path),
               numstat.status == 0 {
                counts = GitDiff.parseNumstat(String(decoding: numstat.output, as: UTF8.self), repoRoot: repo)
            }
            let branch = GitInfo.branch(at: repo)
            DispatchQueue.main.async {
                self.gitRunning = false
                if let snapshot, self.root.flatMap({ GitInfo.repositoryRoot(for: $0) }) == repo {
                    self.git = snapshot
                    self.branch = branch
                    self.repoRoot = repo
                    self.lineCounts = counts
                }
                if self.gitRequestedAgain {
                    self.gitRequestedAgain = false
                    self.refreshGitStatus()
                }
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
        var head = 0
        var visited = 0
        while head < queue.count, results.count < limit, visited < 20_000 {
            let (folder, depth) = queue[head]
            head += 1
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

    /// Opens with the default app for its type (Xcode, VS Code, Preview…).
    func openExternally(_ entry: FileListing.Entry) {
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
            if model.repoRoot != nil {
                SectionSwitch(model: model, palette: palette)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            FilterField(text: $model.filter, placeholder: model.section == .changes ? "Filter changes" : "Filter files", palette: palette)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            if model.section == .changes {
                changesContent
            } else {
                content
            }
            footer
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
                Text("FILES")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(1.2)
                    .foregroundColor(Color(nsColor: palette.hint))
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
        .frame(height: 56)
    }

    /// Branch and number of changed files.
    @ViewBuilder
    private var footer: some View {
        if let branch = model.branch {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(branch).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if model.git.changedFileCount > 0 {
                    Text("\(model.git.changedFileCount) changed")
                        .foregroundColor(Color(nsColor: palette.ansiYellow.withAlphaComponent(0.9)))
                } else {
                    Text("clean")
                }
            }
            .font(.system(size: 11))
            .foregroundColor(Color(nsColor: palette.secondary))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: palette.outline)).frame(height: 1) }
        }
    }

    @ViewBuilder
    private var changesContent: some View {
        let changes = model.changes
        if changes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.filter.trimmingCharacters(in: .whitespaces).isEmpty ? "nothing changed" : "no changes match")
                    .font(.hand(19))
                    .foregroundColor(Color(nsColor: palette.secondary))
                Text("Edited, new and deleted files show up here, compared with the last commit.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(nsColor: palette.hint))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(changes) { change in
                        ChangeRow(change: change, counts: model.lineCounts[change.path], model: model, palette: palette)
                    }
                }
                .padding(.bottom, 10)
            }
        }
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

/// Files | Changes, above the filter (only inside a git repository).
private struct SectionSwitch: View {
    @ObservedObject var model: FileTreeModel
    let palette: ChromePalette

    var body: some View {
        HStack(spacing: 2) {
            segment(.files, "Files", count: nil)
            segment(.changes, "Changes", count: model.git.changedFileCount)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: palette.surface1)))
    }

    private func segment(_ section: FileTreeModel.Section, _ title: String, count: Int?) -> some View {
        let selected = model.section == section
        return Button {
            model.section = section
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: palette.ansiYellow.withAlphaComponent(0.25))))
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundColor(Color(nsColor: selected ? palette.text : palette.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: selected ? palette.background : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A changed file: name, folder, +/− line counts and its git badge. Click shows the diff.
private struct ChangeRow: View {
    let change: FileTreeModel.Change
    let counts: LineCounts?
    @ObservedObject var model: FileTreeModel
    let palette: ChromePalette
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == change.path
        HStack(spacing: 8) {
            Text(change.state.badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(nsColor: GitColors.color(change.state, palette: palette)))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(change.isFolder ? change.name + "/" : change.name)
                    .font(.system(size: 13))
                    .strikethrough(change.state == .deleted)
                    .foregroundColor(Color(nsColor: palette.text))
                    .lineLimit(1)
                    .truncationMode(.middle)
                let folder = (change.relativePath as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder)
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: palette.hint))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let counts {
                HStack(spacing: 4) {
                    if counts.added > 0 { Text("+\(counts.added)").foregroundColor(Color(nsColor: palette.success)) }
                    if counts.removed > 0 { Text("−\(counts.removed)").foregroundColor(Color(nsColor: palette.error)) }
                }
                .font(.system(size: 10.5, design: .monospaced))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: selected ? palette.accent.withAlphaComponent(0.2) : (hovering ? palette.surface1 : .clear)))
                .padding(.horizontal, 6)
        )
        .onHover { hovering = $0 }
        .overlay(ClickCatcher(onClick: { _ in
            model.selection = change.path
            openDiff()
        }, menu: { contextMenu() }))
        .help(change.relativePath)
    }

    private func openDiff() {
        guard let repo = model.repoRoot else { return }
        model.onOpenDiff(change.path, repo, change.state == .untracked)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Show Changes") { openDiff() })
        if change.state != .deleted, !change.isFolder {
            menu.addItem(ClosureMenuItem(title: "Open in Rune") { model.onOpenFile(change.path, true) })
        }
        menu.addItem(ClosureMenuItem(title: "Insert Path in Input") { model.onInsertPath(change.path) })
        menu.addItem(.separator())
        let entry = FileListing.Entry(name: change.name, path: change.path, isDirectory: change.isFolder, isHidden: change.name.hasPrefix("."))
        menu.addItem(ClosureMenuItem(title: "Copy Path") { model.copyPath(entry) })
        if change.state != .deleted {
            menu.addItem(ClosureMenuItem(title: "Reveal in Finder") { model.reveal(entry) })
        }
        return menu
    }
}

enum GitColors {
    static func color(_ state: GitFileState, palette: ChromePalette) -> NSColor {
        switch state {
        case .modified, .renamed: return palette.ansiYellow
        case .added, .untracked: return palette.success
        case .deleted, .conflicted: return palette.error
        case .ignored: return palette.hint
        }
    }
}

private struct FilterField: View {
    @Binding var text: String
    var placeholder = "Filter files"
    let palette: ChromePalette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: palette.hint))
            TextField(placeholder, text: $text)
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

/// Transparent AppKit view that reports clicks (with their click count) and supplies a
/// context menu. Used where SwiftUI tap gestures are unreliable.
struct ClickCatcher: NSViewRepresentable {
    let onClick: (Int) -> Void
    let menu: () -> NSMenu?

    final class CatcherView: NSView {
        var onClick: (Int) -> Void = { _ in }
        var menuProvider: () -> NSMenu? = { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick(event.clickCount) }
        override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onClick = onClick
        view.menuProvider = menu
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
            // set() rather than push/pop: an unbalanced pop can leave the wrong cursor behind.
            (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
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
        .onHover { hovering = $0 }
        // Clicks are handled in AppKit: reliable single/double clicks, first click works in an
        // inactive window, and the right-click menu is attached to the same view.
        .overlay(ClickCatcher(onClick: { clicks in
            model.selection = entry.path
            if entry.isDirectory {
                if row.relativePath == nil, clicks == 1 { model.toggle(entry) }
            } else {
                model.onOpenFile(entry.path, clicks >= 2)
            }
        }, menu: { contextMenu(for: entry) }))
        .help(entry.path)
    }

    private func contextMenu(for entry: FileListing.Entry) -> NSMenu {
        let menu = NSMenu()
        if entry.isDirectory {
            menu.addItem(ClosureMenuItem(title: "cd Into Folder") { model.onChangeDirectory(entry.path) })
            menu.addItem(ClosureMenuItem(title: "New Tab Here") { model.onNewTab(entry.path) })
        } else {
            menu.addItem(ClosureMenuItem(title: "Open in Rune") { model.onOpenFile(entry.path, true) })
            menu.addItem(ClosureMenuItem(title: "Open with Default App") { model.openExternally(entry) })
        }
        menu.addItem(ClosureMenuItem(title: "Insert Path in Input") { model.onInsertPath(entry.path) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy Path") { model.copyPath(entry) })
        menu.addItem(ClosureMenuItem(title: "Reveal in Finder") { model.reveal(entry) })
        return menu
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
        GitColors.color(state, palette: palette)
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
