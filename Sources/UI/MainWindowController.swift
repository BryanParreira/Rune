import AppKit
import Quartz
import Combine
import RuneKit
import SwiftUI

/// Something that can live in a tab: terminal panes, a file, or the Settings page.
protocol TabContent: AnyObject {
    var id: UUID { get }
    var title: String { get }
    /// A program that would be killed by closing this tab, if any.
    var runningProgram: String? { get }
    var contentView: NSView { get }
    func focus()
    func apply(_ snapshot: ConfigSnapshot)
    func closeContent()
}

extension TerminalSession {
    func focus() { view.focusPreferredResponder() }
    func closeContent() {
        onChange = nil
        onRequestClose = nil
        terminate()
    }
}

/// Reports every first-responder change, so the window knows which split pane has focus.
final class RuneWindow: NSWindow {
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { onFirstResponderChange?(firstResponder) }
        return accepted
    }
}

/// One Rune window: custom tab bar in the titlebar, config warning strip, and the active tab.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let tabBarHeight: CGFloat = 38

    private let configStore: ConfigStore
    private var tabs: [TabContent] = []
    private var selectedIndex = 0
    private var cancellables: Set<AnyCancellable> = []

    private let tabsModel: TabsModel
    private let warningModel: WarningModel
    private let contentArea = NSView()
    private let fileTree = FileTreeModel()
    private var fileTreeHost: NSHostingView<FileTreeView>?
    private var fileTreeWidth: NSLayoutConstraint?
    static let fileTreeWidthRange: ClosedRange<CGFloat> = 180...520
    private static let fileTreeWidthKey = "RuneFileTreeWidth"
    /// Last width the user dragged the file tree to (a per-Mac UI preference, not config).
    private var fileTreePreferredWidth: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "RuneFileTreeWidth"))
        return saved > 0 ? min(max(saved, 180), 520) : 260
    }()

    fileprivate var paletteHost: NSHostingView<CommandPaletteView>?
    fileprivate var recallHost: NSHostingView<RecallView>?
    fileprivate var paletteModel: PaletteModel?
    fileprivate var recallModel: RecallModel?

    /// Called after the window closes so the app can drop its reference.
    var onClose: ((MainWindowController) -> Void)?

    /// Called whenever tabs, panes or folders change, so the session can be saved.
    var onStateChange: (() -> Void)?

    init(configStore: ConfigStore, directory: String, restoring saved: SavedSession.Window? = nil, adopting tab: TabContent? = nil) {
        self.configStore = configStore
        let palette = ChromePalette(theme: configStore.snapshot.theme)
        tabsModel = TabsModel(palette: palette)
        warningModel = WarningModel(palette: palette)

        let window = RuneWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 420, height: 240)
        window.tabbingMode = .disallowed
        // Test runs share this Mac's settings; they must never change the user's window size.
        if !AppDelegate.isAutomatedRun { window.setFrameAutosaveName("RuneMainWindow") }
        window.appearance = NSAppearance(named: configStore.snapshot.theme.isLight ? .aqua : .darkAqua)

        super.init(window: window)
        window.delegate = self
        window.onFirstResponderChange = { [weak self] responder in
            guard let self, let tab = self.selectedTab as? TerminalTab else { return }
            // The find bar opening or closing moves focus; re-anchor the output for it.
            tab.focusedSession?.updateBottomTrim()
            if tab.noteFocus(responder) { self.refreshTabs() }
        }

        buildLayout(in: window)
        wireModels()
        applySnapshot(configStore.snapshot)

        configStore.$snapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applySnapshot($0) }
            .store(in: &cancellables)

        if let tab {
            adopt(tab)
        } else if let saved {
            restore(saved)
        } else {
            addTab(directory: directory)
        }
    }

    // MARK: - Session restore

    /// This window's tabs as they should reopen after a relaunch (Settings isn't restored).
    var savedState: SavedSession.Window {
        var saved: [SavedSession.Tab] = []
        var selected = 0
        for (index, tab) in tabs.enumerated() {
            if index == selectedIndex { selected = saved.count }
            if let terminal = tab as? TerminalTab {
                saved.append(terminal.saved)
            } else if let file = tab as? FilePreviewTab, file.isPinned {
                saved.append(.file(path: file.path))
            }
        }
        return SavedSession.Window(frame: window.map { NSStringFromRect($0.frame) }, selectedTab: min(selected, max(0, saved.count - 1)), tabs: saved)
    }

    private func restore(_ saved: SavedSession.Window) {
        if let frame = saved.frame.map(NSRectFromString), frame.width >= 420, frame.height >= 240 {
            window?.setFrame(frame, display: false)
        }
        for tab in saved.tabs { openSavedTab(tab) }
        if tabs.isEmpty { addTab(directory: NSHomeDirectory()) }
        select(index: min(saved.selectedTab, tabs.count - 1))
        #if DEBUG
        if let first = terminalTabs.first?.sessions.first { DebugDriver.runIfRequested(session: first) }
        #endif
    }

    /// Opens a tab from saved state (session restore, launch configurations, reopen closed).
    func openSavedTab(_ tab: SavedSession.Tab) {
        switch tab {
        case .terminal(let layout, let style):
            let terminal = TerminalTab(layout: layout, style: style, palette: ChromePalette(theme: configStore.snapshot.theme)) { directory in
                self.makeSession(directory: directory)
            }
            insert(terminal)
            terminal.sessions.forEach {
                $0.view.dismissWelcomeForSession()
                start($0, prefill: nil)
            }
            if let first = terminal.sessions.first { terminal.focus(first) }
        case .file(let path):
            guard FileManager.default.fileExists(atPath: path) else { return }
            insert(makeFileTab(path: path, pinned: true))
        }
    }

    // MARK: - Launch layouts

    /// Starts each pane's command from a layout; `commands` has one list per tab, in pane order.
    func runStartCommands(_ commands: [[String?]]) {
        for (tab, paneCommands) in zip(terminalTabs, commands) {
            for (session, command) in zip(tab.sessions, paneCommands) {
                if let command { session.runWhenReady(command) }
            }
        }
    }

    /// Shell > Save Window as Layout…: this window's terminal tabs, splits, folders and
    /// running commands, to open again later from the palette or the Shell menu.
    @objc func saveLayout(_ sender: Any?) {
        let terminals = terminalTabs
        guard !terminals.isEmpty, let window, let store = (NSApp.delegate as? AppDelegate)?.layoutStore else { NSSound.beep(); return }
        let layout = currentLayout(named: "")
        let running = terminals.flatMap(\.paneCommands).compactMap { $0 }

        let alert = NSAlert()
        alert.messageText = "Save Window as Layout"
        alert.informativeText = "Opens these \(terminals.count == 1 ? "tabs" : "\(terminals.count) tabs"), splits and folders again from the command palette (⌘P) or Shell > Open Layout."
            + (running.isEmpty ? "" : " Commands running now start again too: " + running.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (running.count > 3 ? "…" : "."))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Layout name"
        field.stringValue = (terminals.first?.focusedSession?.currentDirectory).map { ($0 as NSString).lastPathComponent } ?? "Layout"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            var named = layout
            named.name = name
            let save = { self?.writeLayout(named, to: store) }
            guard store.fileExists(named: name), let window = self?.window else { save(); return }
            let replace = NSAlert()
            replace.messageText = "Replace the layout “\(name)”?"
            replace.informativeText = "A layout with this name already exists."
            replace.addButton(withTitle: "Replace")
            replace.addButton(withTitle: "Cancel")
            DispatchQueue.main.async {
                replace.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { save() } }
            }
        }
    }

    /// This window's terminal tabs as a layout.
    func currentLayout(named name: String) -> LaunchLayout {
        let home = NSHomeDirectory()
        return LaunchLayout(name: name, tabs: terminalTabs.map { tab in
            LaunchLayout.Tab(title: tab.style.title, color: tab.style.color,
                             root: LaunchLayout.Pane(layout: tab.layout, commands: tab.paneCommands, home: home))
        })
    }

    private func writeLayout(_ layout: LaunchLayout, to store: LaunchLayoutStore) {
        do {
            try store.save(layout)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the layout"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    // MARK: - Tab names and colors

    /// Shell > Rename Tab…: edits the selected tab's name in the tab bar.
    @objc func renameTab(_ sender: Any?) {
        guard let terminal = selectedTab as? TerminalTab else { NSSound.beep(); return }
        tabsModel.editingID = terminal.id
    }

    private func setStyle(ofTab id: UUID, _ change: (inout TabStyle) -> Void) {
        guard let terminal = tabs.first(where: { $0.id == id }) as? TerminalTab else { return }
        change(&terminal.style)
        if let title = terminal.style.title?.trimmingCharacters(in: .whitespaces) {
            terminal.style.title = title.isEmpty ? nil : title
        }
        refreshTabs()
    }

    /// Asks once if any of them is running something.
    private func closeOtherTabs(keeping id: UUID) {
        let others = tabs.filter { $0.id != id }
        let close = { [weak self] in
            others.forEach { self?.closeTab(id: $0.id) }
            self?.selectTab(id: id)
        }
        let running = others.compactMap(\.runningProgram)
        guard !running.isEmpty, let window else { return close() }
        let alert = NSAlert()
        alert.messageText = "Close the other tabs?"
        alert.informativeText = Self.describe(running) + " Closing the other tabs will stop \(running.count == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Close Tabs")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { close() }
        }
    }

    // MARK: - Reopen closed tab

    /// ⇧⌘T: the most recently closed tab or pane comes back, in its folders.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let tab = ClosedTabs.shared.pop() else { NSSound.beep(); return }
        openSavedTab(tab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func buildLayout(in window: NSWindow) {
        let root = NSView()
        root.wantsLayer = true

        let tabBar = NSHostingView(rootView: TabBarView(model: tabsModel, leadingInset: TrafficLights.reservedWidth(in: window)))
        let banner = NSHostingView(rootView: WarningBanner(model: warningModel))
        banner.sizingOptions = [.intrinsicContentSize]
        // The banner is exactly as tall as its content (0 when there are no warnings).
        banner.setContentHuggingPriority(.required, for: .vertical)
        banner.setContentCompressionResistancePriority(.required, for: .vertical)
        contentArea.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The tab bar deliberately lives under the transparent titlebar.
        tabBar.safeAreaRegions = []
        // Its height is a constraint; tabs shrink to fit instead of making the window wider.
        tabBar.sizingOptions = []
        banner.safeAreaRegions = []

        let treeHost = NSHostingView(rootView: makeFileTreeView(palette: ChromePalette(theme: configStore.snapshot.theme)))
        treeHost.safeAreaRegions = []
        treeHost.isHidden = true
        fileTreeHost = treeHost
        let treeWidth = treeHost.widthAnchor.constraint(equalToConstant: 0)
        fileTreeWidth = treeWidth

        for view in [tabBar, banner, treeHost, contentArea] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),

            banner.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            treeHost.topAnchor.constraint(equalTo: banner.bottomAnchor),
            treeHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            treeHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            treeWidth,

            contentArea.topAnchor.constraint(equalTo: banner.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: treeHost.trailingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window.contentView = root
        TrafficLights.position(in: window, barHeight: Self.tabBarHeight)
    }

    private func wireModels() {
        tabsModel.onSelect = { [weak self] id in self?.selectTab(id: id) }
        tabsModel.onClose = { [weak self] id in self?.requestCloseTab(id: id) }
        tabsModel.onNew = { [weak self] in self?.newTab(nil) }
        tabsModel.onToggleSidebar = { [weak self] in self?.toggleFileTree(nil) }
        tabsModel.onOpenSettings = { [weak self] in self?.openSettingsTab() }
        tabsModel.onRename = { [weak self] id, title in self?.setStyle(ofTab: id) { $0.title = title } }
        tabsModel.onSetColor = { [weak self] id, color in self?.setStyle(ofTab: id) { $0.color = color } }
        tabsModel.onCloseOthers = { [weak self] id in self?.closeOtherTabs(keeping: id) }
        tabsModel.onDropTab = { [weak self] id, before in self?.dropTab(id: id, before: before) }
        tabsModel.onMoveToNewWindow = { [weak self] id in self?.moveToNewWindow(id) }
        fileTree.onInsertPath = { [weak self] path in
            guard let session = self?.fileTreeSession else { return }
            let quoted = FileListing.shellQuoted(path)
            if session.mode == .editor {
                session.view.inputArea.insertAtCaret(quoted + " ")
            } else {
                session.terminalView.sendToShell(Array((quoted + " ").utf8))
            }
        }
        fileTree.onChangeDirectory = { [weak self] path in
            guard let session = self?.fileTreeSession, session.mode == .editor || session.mode == .shellPrompt else { return }
            if session.mode == .editor {
                session.submit("cd " + FileListing.shellQuoted(path))
            } else {
                session.terminalView.sendToShell(Array(("cd " + FileListing.shellQuoted(path) + "\r").utf8))
            }
        }
        fileTree.onNewTab = { [weak self] path in self?.addTab(directory: path) }
        fileTree.onOpenFile = { [weak self] path, pinned in self?.openFile(path: path, pinned: pinned) }
        fileTree.onOpenDiff = { [weak self] path, repo, untracked in self?.openDiff(path: path, repo: repo, untracked: untracked) }
        warningModel.onOpenConfig = { [weak self] in self?.openSettingsTab() }
    }

    private func applySnapshot(_ snapshot: ConfigSnapshot) {
        let palette = ChromePalette(theme: snapshot.theme)
        tabsModel.palette = palette
        warningModel.palette = palette
        if warningModel.warnings != snapshot.warnings {
            warningModel.warnings = snapshot.warnings
            warningModel.dismissed = false
        }
        fileTreeHost?.rootView = makeFileTreeView(palette: palette)
        window?.backgroundColor = palette.background
        window?.appearance = NSAppearance(named: snapshot.theme.isLight ? .aqua : .darkAqua)
        window?.contentView?.layer?.backgroundColor = palette.background.cgColor
        for tab in tabs {
            tab.apply(snapshot)
        }
    }

    // MARK: - Tabs

    private var selectedTab: TabContent? {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
    }

    /// The focused pane of the selected terminal tab.
    var selectedSession: TerminalSession? {
        (selectedTab as? TerminalTab)?.focusedSession
    }

    private var terminalTabs: [TerminalTab] { tabs.compactMap { $0 as? TerminalTab } }

    /// Every shell in this window (for a problem report).
    var allSessions: [TerminalSession] { terminalTabs.flatMap(\.sessions) }

    /// The session new tabs inherit their directory from (the selected one, or the last terminal).
    private var directorySource: TerminalSession? {
        selectedSession ?? terminalTabs.last?.focusedSession
    }

    func addTab(directory: String, prefill: String? = nil) {
        let session = makeSession(directory: directory)
        let tab = TerminalTab(session: session, palette: ChromePalette(theme: configStore.snapshot.theme))
        insert(tab)
        start(session, prefill: prefill)
        #if DEBUG
        if tabs.count == 1 { DebugDriver.runIfRequested(session: session) }
        #endif
    }

    private func makeSession(directory: String) -> TerminalSession {
        let snapshot = configStore.snapshot
        let session = SessionPool.shared.take(snapshot: snapshot, directory: directory)
            ?? TerminalSession(snapshot: snapshot, directory: directory)
        wire(session)
        return session
    }

    /// Points a session's requests (new tab, close, open file…) at this window.
    private func wire(_ session: TerminalSession) {
        session.onChange = { [weak self] in self?.refreshTabs() }
        session.onRequestNewTab = { [weak self, weak session] text in
            self?.addTab(directory: session?.currentDirectory ?? NSHomeDirectory(), prefill: text)
        }
        session.onRequestClose = { [weak self, weak session] in
            guard let self, let session else { return }
            self.closePane(session)
        }
        session.onWatch = { [weak self] command, directory, shell, path in
            guard let self else { return }
            self.insert(WatchTab(command: command, directory: directory, shell: shell, path: path, snapshot: self.configStore.snapshot))
        }
        session.onCompare = { [weak self] old, new in
            guard let self else { return }
            self.insert(OutputCompareTab(old: old, new: new, snapshot: self.configStore.snapshot))
        }
        session.onOpenFile = { [weak self] path, line in
            self?.openFile(path: path, pinned: true)
            if let line, let preview = self?.selectedTab as? FilePreviewTab { preview.reveal(line: line) }
        }
    }

    private func start(_ session: TerminalSession, prefill: String?) {
        // Size the view before the shell starts so it gets the right winsize immediately.
        contentArea.layoutSubtreeIfNeeded()
        SessionPool.shared.preferredSize = contentArea.bounds.size
        if session.state == .notStarted { session.start() }
        session.focus()
        if let prefill { session.view.inputArea.setText(prefill) }
    }

    /// Splits the focused pane: side by side (`vertical`) or stacked.
    func splitPane(vertical: Bool) {
        guard let tab = selectedTab as? TerminalTab else { return }
        let session = makeSession(directory: tab.focusedSession?.currentDirectory ?? NSHomeDirectory())
        tab.split(adding: session, vertical: vertical)
        // The shortcut tips are for a fresh tab; in a split they'd crowd out the output.
        session.view.dismissWelcomeForSession()
        start(session, prefill: nil)
        refreshTabs()
    }

    /// Closes one pane (the whole tab when it's the last one).
    private func closePane(_ session: TerminalSession) {
        guard let tab = terminalTabs.first(where: { $0.contains(session) }) else { return }
        if tab.paneCount > 1 { ClosedTabs.shared.push(.terminal(.pane(directory: session.currentDirectory))) }
        if !tab.remove(session) {
            closeTab(id: tab.id)
        } else {
            refreshTabs()
        }
    }

    /// The tab and pane showing `sessionID`, brought to the front (e.g. from a notification).
    @discardableResult
    func reveal(sessionID: UUID) -> Bool {
        for (index, tab) in tabs.enumerated() {
            guard let terminal = tab as? TerminalTab,
                  let session = terminal.sessions.first(where: { $0.id == sessionID }) else { continue }
            select(index: index)
            terminal.focus(session)
            window?.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    /// Every tab, for the command palette.
    var tabSummaries: [(id: UUID, title: String, isSelected: Bool)] {
        tabs.enumerated().map { ($1.id, $1.title, $0 == selectedIndex) }
    }

    func selectTab(withID id: UUID) { selectTab(id: id) }

    /// Shows the Settings tab, creating it next to the current tab if needed.
    func openSettingsTab() {
        if let index = tabs.firstIndex(where: { $0 is SettingsTab }) {
            select(index: index)
            return
        }
        insert(SettingsTab(store: configStore))
    }

    #if DEBUG
    func debugSettings() -> SettingsTab? { selectedTab as? SettingsTab }

    func debugSelectedPreview() -> FilePreviewView? {
        (selectedTab as? FilePreviewTab)?.contentView as? FilePreviewView
    }

    /// `name|color` for the selected tab, through the same calls as the tab bar.
    func debugStyleSelectedTab(_ spec: String) {
        guard let id = selectedTab?.id else { return }
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if let name = parts.first, !name.isEmpty { tabsModel.onRename(id, name == "-" ? "" : name) }
        if parts.count > 1 { tabsModel.onSetColor(id, TabColor(rawValue: parts[1])) }
    }

    /// Shows the sidebar's Changes list, prints it, and opens the diff of change `index` (if any).
    func debugChanges(open index: Int?) {
        if !tabsModel.sidebarVisible { toggleFileTree(nil) }
        fileTree.section = .changes
        let changes = fileTree.changes
        print("CHANGES repo=\(fileTree.repoRoot ?? "-") " + changes.map { "\($0.relativePath)[\($0.state.badge)\(fileTree.lineCounts[$0.path].map { " +\($0.added)-\($0.removed)" } ?? "")]" }.joined(separator: " "))
        fflush(stdout)
        if let index, changes.indices.contains(index), let repo = fileTree.repoRoot {
            openDiff(path: changes[index].path, repo: repo, untracked: changes[index].state == .untracked)
        }
    }

    func debugDumpTabs() {
        for (i, tab) in tabs.enumerated() {
            let kind = tab is FilePreviewTab ? ((tab as? FilePreviewTab)?.isPinned == true ? "file(pinned)" : "file(preview)") : String(describing: type(of: tab))
            let style = (tab as? TerminalTab).map {
                " style=\($0.style.title ?? "-")/\($0.style.color?.rawValue ?? "-") panes=\($0.layout) running=\($0.paneCommands)"
            } ?? ""
            print("TABS \(i)\(i == selectedIndex ? "*" : " ") \(kind) \(tab.title)\(style)")
        }
        if let preview = selectedTab as? FilePreviewTab, let view = preview.contentView as? FilePreviewView {
            print("TABS preview " + view.debugSummary)
        }
        fflush(stdout)
    }
    #endif

    /// Shows a file in a Rune tab. Unpinned opens reuse the current preview tab.
    func openFile(path: String, pinned: Bool) {
        if let index = tabs.firstIndex(where: { ($0 as? FilePreviewTab)?.path == path }) {
            if pinned, let tab = tabs[index] as? FilePreviewTab { tab.isPinned = true }
            select(index: index)
            return
        }
        if !pinned, let index = tabs.firstIndex(where: { ($0 as? FilePreviewTab)?.isPinned == false }),
           let preview = tabs[index] as? FilePreviewTab {
            preview.show(path: path)
            select(index: index)
            return
        }
        insert(makeFileTab(path: path, pinned: pinned))
    }

    /// Opens the sidebar on its Changes list.
    @objc func showGitChanges(_ sender: Any?) {
        if !tabsModel.sidebarVisible { toggleFileTree(nil) }
        fileTree.section = .changes
    }

    /// A changed file's diff; one tab per file (clicking it again selects that tab).
    func openDiff(path: String, repo: String, untracked: Bool) {
        if let index = tabs.firstIndex(where: { ($0 as? DiffTab)?.path == path }) {
            select(index: index)
            return
        }
        insert(DiffTab(path: path, repo: repo, untracked: untracked, snapshot: configStore.snapshot) { [weak self] file in
            self?.openFile(path: file, pinned: true)
        })
    }

    private func makeFileTab(path: String, pinned: Bool) -> FilePreviewTab {
        let tab = FilePreviewTab(path: path, pinned: pinned, snapshot: configStore.snapshot)
        tab.onRunSnippet = { [weak self] command, folder in self?.runSnippet(command, from: folder) }
        return tab
    }

    /// A "Run…" button in a Markdown preview: put the command in the terminal's input (the
    /// user presses Return), from the project the document belongs to.
    private func runSnippet(_ command: String, from folder: String) {
        guard let session = directorySource,
              let index = tabs.firstIndex(where: { ($0 as? TerminalTab)?.contains(session) == true }),
              let tab = tabs[index] as? TerminalTab else {
            addTab(directory: GitInfo.repositoryRoot(for: folder) ?? folder, prefill: command)
            return
        }
        let target = GitInfo.repositoryRoot(for: folder) ?? folder
        let text = session.currentDirectory == target ? command : "cd \(FileListing.shellQuoted(target)) && " + command
        select(index: index)
        tab.focus(session)
        switch session.mode {
        case .editor: session.view.inputArea.setText(text)
        case .shellPrompt: session.terminalView.sendToShell(Array(text.utf8))
        default: addTab(directory: target, prefill: command)
        }
    }

    private func insert(_ tab: TabContent) {
        let view = tab.contentView
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        contentArea.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentArea.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
        let insertAt = tabs.isEmpty ? 0 : selectedIndex + 1
        tabs.insert(tab, at: insertAt)
        select(index: insertAt)
    }

    // MARK: - Moving tabs

    /// Takes a tab out of this window without closing it (it's moving to another window).
    func detachTab(id: UUID) -> TabContent? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        tab.contentView.removeFromSuperview()
        if tabs.isEmpty {
            window?.close()
        } else {
            select(index: min(index < selectedIndex ? selectedIndex - 1 : selectedIndex, tabs.count - 1))
        }
        return tab
    }

    /// Takes in a tab from another window, before the tab `before` (or after the selected one).
    func adopt(_ tab: TabContent, before: UUID? = nil) {
        if let terminal = tab as? TerminalTab {
            terminal.sessions.forEach(wire)
            terminal.apply(configStore.snapshot)
        } else if let file = tab as? FilePreviewTab {
            file.onRunSnippet = { [weak self] command, folder in self?.runSnippet(command, from: folder) }
        }
        insert(tab)
        if let before, let target = tabs.firstIndex(where: { $0.id == before }), let index = tabs.firstIndex(where: { $0 === tab }) {
            moveTab(from: index, to: target)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// A tab dropped on this window's tab bar: reordered here, or brought over from another window.
    func dropTab(id: UUID, before: UUID?) {
        guard id != before else { return }
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            let target = before.flatMap { b in tabs.firstIndex(where: { $0.id == b }) } ?? tabs.count
            moveTab(from: index, to: target)
        } else if let source = (NSApp.delegate as? AppDelegate)?.controller(owningTab: id), source !== self,
                  let tab = source.detachTab(id: id) {
            adopt(tab, before: before)
            // Dropped on the + (no tab after it): it goes last.
            if before == nil, let index = tabs.firstIndex(where: { $0 === tab }) { moveTab(from: index, to: tabs.count) }
        }
    }

    /// Moves the tab at `from` to just before position `to` (in the order before the move).
    private func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let selected = selectedTab
        let tab = tabs.remove(at: from)
        let destination = min(to > from ? to - 1 : to, tabs.count)
        tabs.insert(tab, at: destination)
        if let selected, let index = tabs.firstIndex(where: { $0 === selected }) { selectedIndex = index }
        refreshTabs()
    }

    func containsTab(id: UUID) -> Bool { tabs.contains { $0.id == id } }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        if let id = selectedTab?.id { moveToNewWindow(id) }
    }

    private func moveToNewWindow(_ id: UUID) {
        guard tabs.count > 1, let tab = detachTab(id: id) else { return NSSound.beep() }
        (NSApp.delegate as? AppDelegate)?.newWindow(adopting: tab, cascadingFrom: window)
    }

    private func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        for (i, tab) in tabs.enumerated() {
            tab.contentView.isHidden = i != index
        }
        refreshTabs()
        selectedTab?.focus()
    }

    private func selectTab(id: UUID) {
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            select(index: index)
        }
    }

    private func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if let terminal = tab as? TerminalTab {
            ClosedTabs.shared.push(terminal.saved)
        } else if let file = tab as? FilePreviewTab {
            ClosedTabs.shared.push(.file(path: file.path))
        }
        tab.closeContent()
        tab.contentView.removeFromSuperview()

        if tabs.isEmpty {
            window?.close()
            return
        }
        let next = index < selectedIndex || selectedIndex >= tabs.count ? max(0, selectedIndex - 1) : selectedIndex
        select(index: min(next, tabs.count - 1))
    }

    /// The terminal the file tree follows: the selected one, or the last terminal tab.
    private var fileTreeSession: TerminalSession? { directorySource }

    private func refreshTabs() {
        tabsModel.tabs = tabs.map { tab in
            let terminal = tab as? TerminalTab
            return TabItem(id: tab.id, title: tab.title, isPreview: (tab as? FilePreviewTab)?.isPinned == false,
                           color: terminal?.style.color, customTitle: terminal.map { $0.style.title } ?? nil, canStyle: terminal != nil)
        }
        tabsModel.selectedID = selectedTab?.id
        if let directory = fileTreeSession?.currentDirectory {
            fileTree.setRoot(directory)
        }
        window?.title = selectedTab?.title ?? "Rune"
        onStateChange?()
    }

    // MARK: - Menu actions (responder chain)

    @objc func newTab(_ sender: Any?) {
        addTab(directory: directorySource?.currentDirectory ?? NSHomeDirectory())
    }

    /// ⌘W: closes the focused pane when the tab is split, otherwise the tab.
    @objc func closeTab(_ sender: Any?) {
        if let tab = selectedTab as? TerminalTab, tab.paneCount > 1, let session = tab.focusedSession {
            requestClosePane(session, in: tab)
        } else if let tab = selectedTab {
            requestCloseTab(id: tab.id)
        }
    }

    private func requestClosePane(_ session: TerminalSession, in tab: TerminalTab) {
        guard let program = session.runningProgram, let window else {
            closePane(session)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "“\(program)” is still running in this pane. Closing it will stop it."
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self, weak session] response in
            guard response == .alertFirstButtonReturn, let session else { return }
            self?.closePane(session)
        }
    }

    /// ⌘F / ⌘G / ⇧⌘G: search the focused pane's output, or the open file.
    @objc func findInTab(_ sender: NSMenuItem) {
        let request = NSMenuItem()
        request.tag = sender.tag
        if let session = selectedSession {
            session.find(NSTextFinder.Action(rawValue: sender.tag) ?? .showFindInterface)
        } else if let preview = selectedTab as? FilePreviewTab {
            preview.find(request)
        }
    }

    @objc func splitRight(_ sender: Any?) { splitPane(vertical: true) }
    @objc func splitDown(_ sender: Any?) { splitPane(vertical: false) }
    @objc func selectNextPane(_ sender: Any?) { (selectedTab as? TerminalTab)?.cyclePane(forward: true); refreshTabs() }
    @objc func selectPreviousPane(_ sender: Any?) { (selectedTab as? TerminalTab)?.cyclePane(forward: false); refreshTabs() }
    @objc func selectPaneLeft(_ sender: Any?) { movePane(.left) }
    @objc func selectPaneRight(_ sender: Any?) { movePane(.right) }
    @objc func selectPaneAbove(_ sender: Any?) { movePane(.up) }
    @objc func selectPaneBelow(_ sender: Any?) { movePane(.down) }

    private func movePane(_ direction: TerminalTab.Direction) {
        (selectedTab as? TerminalTab)?.movePane(direction)
        refreshTabs()
    }

    /// Split and pane commands only apply to terminal tabs.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let paneActions: [Selector] = [#selector(splitRight(_:)), #selector(splitDown(_:))]
        let navigation: [Selector] = [#selector(selectNextPane(_:)), #selector(selectPreviousPane(_:)), #selector(selectPaneLeft(_:)),
                                      #selector(selectPaneRight(_:)), #selector(selectPaneAbove(_:)), #selector(selectPaneBelow(_:))]
        guard let action = item.action else { return true }
        if paneActions.contains(action) { return selectedTab is TerminalTab }
        if action == #selector(reopenClosedTab(_:)) { return !ClosedTabs.shared.isEmpty }
        if action == #selector(renameTab(_:)) { return selectedTab is TerminalTab }
        if action == #selector(saveLayout(_:)) { return !terminalTabs.isEmpty }
        if navigation.contains(action) { return ((selectedTab as? TerminalTab)?.paneCount ?? 0) > 1 }
        return true
    }

    /// Programs that would be killed by closing this window.
    var runningPrograms: [String] {
        tabs.compactMap(\.runningProgram)
    }

    /// Closes a tab, asking first if a program is still running in it.
    private func requestCloseTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        guard let program = tab.runningProgram, let window else {
            closeTab(id: id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText = "“\(program)” is still running in this tab. Closing it will stop it."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.closeTab(id: id) }
        }
    }

    private var confirmedWindowClose = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let programs = runningPrograms
        guard !programs.isEmpty, !confirmedWindowClose else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = Self.describe(programs) + " Closing the window will stop \(programs.count == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.confirmedWindowClose = true
            sender.close()
        }
        return false
    }

    static func describe(_ programs: [String]) -> String {
        let unique = Array(NSOrderedSet(array: programs)) as? [String] ?? programs
        let list = unique.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        let more = unique.count > 3 ? " and \(unique.count - 3) more" : ""
        return programs.count == 1 ? "\(list) is still running." : "\(list)\(more) are still running."
    }

    @objc func openSettings(_ sender: Any?) {
        openSettingsTab()
    }

    /// Opens a terminal tab with `ollama pull <suggested>` typed in (the user presses Enter).
    @objc func pullSuggestedModel(_ sender: Any?) {
        addTab(directory: directorySource?.currentDirectory ?? NSHomeDirectory(),
               prefill: "ollama pull \(ModelSelection.suggestedModel)")
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // Tag 1–8 select that tab; 9 selects the last tab, like browsers.
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        select(index: index)
    }

    private func makeFileTreeView(palette: ChromePalette) -> FileTreeView {
        FileTreeView(
            model: fileTree,
            palette: palette,
            onResize: { [weak self] x in
                guard let self, let width = self.fileTreeWidth, let host = self.fileTreeHost, !host.isHidden else { return }
                let clamped = min(max(x, Self.fileTreeWidthRange.lowerBound), Self.fileTreeWidthRange.upperBound)
                width.constant = clamped
                self.fileTreePreferredWidth = clamped
            },
            onResizeEnded: { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(Double(self.fileTreePreferredWidth), forKey: Self.fileTreeWidthKey)
            }
        )
    }

    @objc func toggleFileTree(_ sender: Any?) {
        guard let host = fileTreeHost, let width = fileTreeWidth else { return }
        let show = host.isHidden
        tabsModel.sidebarVisible = show
        fileTree.isActive = show
        // Not animated: every animation frame would resize the terminal, reflowing its output
        // and sending the shell a resize signal each time.
        host.isHidden = !show
        width.constant = show ? fileTreePreferredWidth : 0
        // Files are about to be opened: start the Markdown engine now rather than at launch,
        // so people who never preview files never pay for it.
        if show { DispatchQueue.main.async { MarkdownWebEngine.prewarm() } }
        window?.contentView?.layoutSubtreeIfNeeded()
        if !show { selectedTab?.focus() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["RUNE_DEBUG_SCRIPT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                print("TREE visible=\(!host.isHidden) width=\(host.frame.width) root=\(self.fileTree.root ?? "-") rows=\(self.fileTree.rows.count) first=\(self.fileTree.rows.prefix(6).map(\.entry.name)) git=\(self.fileTree.git.states.count)")
                fflush(stdout)
            }
        }
        #endif
    }

    @objc func selectPreviousBlock(_ sender: Any?) {
        selectedSession?.selectAdjacentBlock(previous: true)
    }

    @objc func selectNextBlock(_ sender: Any?) {
        selectedSession?.selectAdjacentBlock(previous: false)
    }

    @objc func extendSelectionUp(_ sender: Any?) {
        selectedSession?.selectAdjacentBlock(previous: true, extend: true)
    }

    @objc func extendSelectionDown(_ sender: Any?) {
        selectedSession?.selectAdjacentBlock(previous: false, extend: true)
    }

    @objc func toggleBookmark(_ sender: Any?) {
        selectedSession?.toggleBookmarkOnCurrentBlock()
    }

    @objc func previousBookmark(_ sender: Any?) {
        selectedSession?.jumpToBookmark(previous: true)
    }

    @objc func nextBookmark(_ sender: Any?) {
        selectedSession?.jumpToBookmark(previous: false)
    }

    @objc func previousError(_ sender: Any?) {
        selectedSession?.jumpToError(previous: true)
    }

    @objc func nextError(_ sender: Any?) {
        selectedSession?.jumpToError(previous: false)
    }

    /// ⌘Y: Quick Look the file named under the mouse pointer in the output.
    @objc func quickLookPath(_ sender: Any?) {
        guard let path = selectedSession?.filePathUnderPointer() else { return NSSound.beep() }
        QuickLook.shared.show([URL(fileURLWithPath: path)])
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !QuickLook.shared.urls.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLook.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    @objc func compareRuns(_ sender: Any?) {
        selectedSession?.compareLatestRuns()
    }

    @objc func copyLatestOutput(_ sender: Any?) {
        selectedSession?.copyLatestOutput()
    }

    @objc func copyLatestBlockImage(_ sender: Any?) {
        selectedSession?.copyLatestBlock(as: .image)
    }

    @objc func clearScreen(_ sender: Any?) {
        selectedSession?.clearScreen()
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        select(index: (selectedIndex + 1) % tabs.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        select(index: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        if let window { TrafficLights.position(in: window, barHeight: Self.tabBarHeight) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window { TrafficLights.position(in: window, barHeight: Self.tabBarHeight) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window { TrafficLights.position(in: window, barHeight: Self.tabBarHeight) }
        selectedTab?.focus()
    }

    func windowWillClose(_ notification: Notification) {
        cancellables.removeAll()
        tabs.forEach { $0.closeContent() }
        tabs.removeAll()
        onClose?(self)
    }
}

// MARK: - Recall

extension MainWindowController {
    /// ⌃R in the editor, ⇧⌘H, or the palette: search everything run in Rune.
    @objc func showRecall(_ sender: Any?) {
        if recallHost != nil {
            closeRecall()
            return
        }
        guard let root = window?.contentView else { return }
        let model = RecallModel(
            palette: ChromePalette(theme: configStore.snapshot.theme),
            onClose: { [weak self] in self?.closeRecall() },
            onInsert: { [weak self] command in self?.insertCommand(command, asWorkflow: false) },
            onOpenFolder: { [weak self] folder in self?.changeDirectory(to: folder) }
        )
        let host = NSHostingView(rootView: RecallView(model: model))
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.topAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        recallHost = host
        recallModel = model
    }

    func closeRecall() {
        recallHost?.removeFromSuperview()
        recallHost = nil
        recallModel = nil
        selectedTab?.focus()
    }
}

// MARK: - Command palette

extension MainWindowController {
    @objc func showCommandPalette(_ sender: Any?) {
        // ⌘P again closes it.
        if paletteHost != nil {
            closeCommandPalette()
            return
        }
        guard let root = window?.contentView else { return }
        let model = PaletteModel(items: paletteItems(), palette: ChromePalette(theme: configStore.snapshot.theme)) { [weak self] in
            self?.closeCommandPalette()
        }
        let host = NSHostingView(rootView: CommandPaletteView(model: model))
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.topAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        paletteHost = host
        paletteModel = model
    }

    func closeCommandPalette() {
        paletteHost?.removeFromSuperview()
        paletteHost = nil
        paletteModel = nil
        selectedTab?.focus()
    }

    private func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func action(_ title: String, _ symbol: String, _ shortcut: String? = nil, keywords: String = "", _ run: @escaping () -> Void) {
            items.append(PaletteItem(id: "action:" + title, kind: .action, title: title, symbol: symbol, shortcut: shortcut, keywords: keywords, run: run))
        }
        let isTerminal = selectedTab is TerminalTab
        let panes = (selectedTab as? TerminalTab)?.paneCount ?? 0

        // Actions
        action("New Tab", "plus.square", "⌘T") { [weak self] in self?.newTab(nil) }
        action("New Window", "macwindow.badge.plus", "⌘N") { NSApp.sendAction(#selector(AppDelegate.newWindow(_:)), to: nil, from: nil) }
        if isTerminal {
            action("Split Pane Right", "rectangle.split.2x1", "⌘D", keywords: "vertical side") { [weak self] in self?.splitPane(vertical: true) }
            action("Split Pane Down", "rectangle.split.1x2", "⇧⌘D", keywords: "horizontal below") { [weak self] in self?.splitPane(vertical: false) }
            action("Rename Tab…", "character.cursor.ibeam", keywords: "name title label color") { [weak self] in self?.renameTab(nil) }
        }
        if !ClosedTabs.shared.isEmpty {
            action("Reopen Closed Tab", "arrow.uturn.backward.square", "⇧⌘T", keywords: "undo close restore") { [weak self] in self?.reopenClosedTab(nil) }
        }
        if panes > 1 {
            action("Close Pane", "xmark.rectangle", "⌘W") { [weak self] in self?.closeTab(nil) }
            action("Focus Next Pane", "arrow.right.square", "⌘]") { [weak self] in self?.selectNextPane(nil) }
        } else {
            action("Close Tab", "xmark.square", "⌘W") { [weak self] in self?.closeTab(nil) }
        }
        action("Toggle File Tree", "sidebar.left", "⌘B", keywords: "files sidebar explorer") { [weak self] in self?.toggleFileTree(nil) }
        if let directory = selectedSession?.currentDirectory, GitInfo.repositoryRoot(for: directory) != nil {
            action("Show Git Changes", "plusminus", keywords: "git diff status modified sidebar") { [weak self] in self?.showGitChanges(nil) }
        }
        if configStore.snapshot.config.recallEnabled {
            action("Recall: Search History", "clock.arrow.circlepath", "⌃R", keywords: "history output search find past") { [weak self] in
                self?.showRecall(nil)
            }
        }
        if isTerminal {
            action("Clear Screen", "eraser", "⌘K") { [weak self] in self?.clearScreen(nil) }
            action("Select Previous Block", "arrow.up.square", "⌘↑") { [weak self] in self?.selectPreviousBlock(nil) }
            action("Copy Last Output", "doc.on.doc", "⇧⌘C", keywords: "clipboard result") { [weak self] in self?.copyLatestOutput(nil) }
            action("Jump to Error", "exclamationmark.triangle", "⌘'", keywords: "failed failure exception panic compiler next") { [weak self] in
                self?.previousError(nil)
            }
            action("Watch Last Command", "eye", keywords: "repeat rerun loop interval live refresh files change") { [weak self] in
                self?.selectedSession?.watchLatest()
            }
            action("Bookmark Block", "bookmark", "⌥⌘B", keywords: "pin mark remember") { [weak self] in self?.toggleBookmark(nil) }
            action("Previous Bookmark", "bookmark.fill", "⌃⌘↑", keywords: "jump pinned") { [weak self] in self?.previousBookmark(nil) }
            action("Compare with Previous Run", "arrow.left.arrow.right", "⌥⌘D", keywords: "diff changes output before after test") { [weak self] in
                self?.compareRuns(nil)
            }
            action("Copy Last Block as Image", "photo", "⌥⌘C", keywords: "screenshot picture png share") { [weak self] in self?.copyLatestBlockImage(nil) }
            action("Copy Last Block as Markdown", "text.badge.checkmark", keywords: "clipboard code fence share issue") { [weak self] in
                self?.selectedSession?.copyLatestBlock(as: .markdown)
            }
        }
        action("Settings", "gearshape", "⌘,", keywords: "preferences") { [weak self] in self?.openSettingsTab() }
        action("Open config.json", "doc.text", keywords: "settings file edit") { NSApp.sendAction(#selector(AppDelegate.openConfig(_:)), to: nil, from: nil) }
        action("Reload Config", "arrow.clockwise", "⇧⌘R") { NSApp.sendAction(#selector(AppDelegate.reloadConfig(_:)), to: nil, from: nil) }
        if UpdateController.shared.isAvailable {
            action("Check for Updates…", "arrow.down.circle", keywords: "upgrade version") { UpdateController.shared.checkForUpdates(nil) }
        }
        if TouchIDSudo.isAvailable, !TouchIDSudo.isEnabled {
            action("Use Touch ID for sudo…", "touchid", keywords: "fingerprint password admin") {
                if case .failed(let reason) = TouchIDSudo.set(enabled: true) {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't turn on Touch ID for sudo"
                    alert.informativeText = reason
                    alert.runModal()
                }
            }
        }
        action("Welcome Guide", "hand.wave", keywords: "onboarding permissions setup") { NSApp.sendAction(#selector(AppDelegate.showOnboarding(_:)), to: nil, from: nil) }

        // Launch layouts
        if !terminalTabs.isEmpty {
            action("Save Window as Layout…", "square.and.arrow.down.on.square", keywords: "launch configuration workspace tabs splits") { [weak self] in self?.saveLayout(nil) }
        }
        if let delegate = NSApp.delegate as? AppDelegate {
            for entry in delegate.layoutStore?.loadAll() ?? [] {
                let tabs = entry.layout.tabs.count
                items.append(PaletteItem(id: "layout:" + entry.file.path, kind: .layout, title: entry.layout.name,
                                         subtitle: "Open in a new window · \(tabs) tab\(tabs == 1 ? "" : "s")",
                                         symbol: "rectangle.3.group", keywords: "layout launch configuration workspace") {
                    delegate.openLayout(entry.layout)
                })
            }
        }

        // Workflows
        for workflow in configStore.snapshot.config.workflows {
            items.append(PaletteItem(id: "workflow:" + workflow.id, kind: .workflow, title: workflow.name, subtitle: workflow.command,
                                     symbol: "bolt", keywords: workflow.description ?? "") { [weak self] in
                self?.insertCommand(workflow.command, asWorkflow: true)
            })
        }

        // Workflows shared by the project (.rune/workflows.json), for the focused pane's folder.
        if let directory = selectedSession?.currentDirectory, let project = ProjectWorkflows.load(for: directory) {
            let projectName = (project.root as NSString).lastPathComponent
            for workflow in project.workflows {
                items.append(PaletteItem(id: "project:" + workflow.id, kind: .projectWorkflow, title: workflow.name,
                                         subtitle: workflow.command, symbol: "bolt.horizontal",
                                         keywords: "project \(projectName) " + (workflow.description ?? "")) { [weak self] in
                    self?.insertCommand(workflow.command, asWorkflow: true)
                })
            }
        }

        // Tabs
        for tab in tabSummaries where !tab.isSelected {
            items.append(PaletteItem(id: "tab:\(tab.id)", kind: .tab, title: tab.title, subtitle: "Switch to tab", symbol: "square.on.square") { [weak self] in
                self?.selectTab(withID: tab.id)
            })
        }

        // Recent folders
        let current = selectedSession?.currentDirectory
        for path in RecentDirectories.shared.paths.prefix(20) where path != current {
            let display = TabTitle.abbreviate(path: path, home: NSHomeDirectory())
            items.append(PaletteItem(id: "folder:" + path, kind: .folder, title: (path as NSString).lastPathComponent, subtitle: display,
                                     symbol: "folder") { [weak self] in
                self?.changeDirectory(to: path)
            })
        }

        // Themes
        let currentTheme = configStore.snapshot.config.theme
        for theme in configStore.availableThemes() {
            items.append(PaletteItem(id: "theme:" + theme, kind: .theme, title: "Theme: " + theme,
                                     subtitle: theme == currentTheme ? "Current theme" : nil, symbol: "paintpalette",
                                     keywords: "appearance colors") { [weak self] in
                self?.configStore.write(key: "theme", value: theme)
            })
        }

        // History (newest first, unique)
        var seen = Set<String>()
        for command in HistoryStore.shared.history.entries.reversed() where seen.insert(command).inserted {
            items.append(PaletteItem(id: "history:" + command, kind: .history, title: command, symbol: "clock.arrow.circlepath") { [weak self] in
                self?.insertCommand(command, asWorkflow: false)
            })
            if seen.count >= 300 { break }
        }
        return items
    }

    /// Puts a command in the focused pane's input (never runs it).
    fileprivate func insertCommand(_ command: String, asWorkflow: Bool) {
        guard let session = selectedSession else { return }
        switch session.mode {
        case .editor:
            if asWorkflow {
                session.view.inputArea.insertWorkflow(command)
            } else {
                session.view.inputArea.setText(command)
            }
        case .shellPrompt:
            session.terminalView.sendToShell(Array(command.utf8))
            session.focus()
        default:
            NSSound.beep()
        }
    }

    fileprivate func changeDirectory(to path: String) {
        guard let session = selectedSession else { return }
        let command = "cd " + FileListing.shellQuoted(path)
        switch session.mode {
        case .editor: session.submit(command)
        case .shellPrompt: session.terminalView.sendToShell(Array((command + "\r").utf8))
        default: NSSound.beep()
        }
    }
}

#if DEBUG
extension MainWindowController {
    var debugPalette: PaletteModel? { paletteModel }
    var debugRecall: RecallModel? { recallModel }

    func debugPanes() {
        guard let tab = selectedTab as? TerminalTab else { print("PANES none"); return }
        for session in tab.sessions {
            let frame = session.view.convert(session.view.bounds, to: nil)
            let focus = session === tab.focusedSession ? "*" : " "
            print("PANES \(focus) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) cols=\(session.terminalView.getTerminal().cols) rows=\(session.terminalView.getTerminal().rows) alpha=\(session.view.alphaValue) cwd=\(session.currentDirectory) blocks=\(session.tracker.blocks.count) mode=\(session.mode)")
        }
        print("PANES count=\(tab.paneCount) tabs=\(tabs.count)")
        fflush(stdout)
    }
}
#endif
