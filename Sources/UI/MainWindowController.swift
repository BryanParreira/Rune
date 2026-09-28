import AppKit
import Combine
import RuneKit
import SwiftUI

/// Something that can live in a tab: a terminal session or the Settings page.
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

extension TerminalSession: TabContent {
    var contentView: NSView { view }
    func focus() { view.focusPreferredResponder() }
    func closeContent() {
        onChange = nil
        onRequestClose = nil
        terminate()
    }
}

/// One Rune window: custom tab bar in the titlebar, config warning strip, and the active tab.
final class MainWindowController: NSWindowController, NSWindowDelegate {
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

    /// Called after the window closes so the app can drop its reference.
    var onClose: ((MainWindowController) -> Void)?

    init(configStore: ConfigStore, directory: String) {
        self.configStore = configStore
        let palette = ChromePalette(theme: configStore.snapshot.theme)
        tabsModel = TabsModel(palette: palette)
        warningModel = WarningModel(palette: palette)

        let window = NSWindow(
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
        window.setFrameAutosaveName("RuneMainWindow")
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)
        window.delegate = self

        buildLayout(in: window)
        wireModels()
        applySnapshot(configStore.snapshot)

        configStore.$snapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applySnapshot($0) }
            .store(in: &cancellables)

        addTab(directory: directory)
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
        // The tab bar deliberately lives under the transparent titlebar.
        tabBar.safeAreaRegions = []
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
        window?.contentView?.layer?.backgroundColor = palette.background.cgColor
        for tab in tabs {
            tab.apply(snapshot)
        }
    }

    // MARK: - Tabs

    private var selectedTab: TabContent? {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
    }

    var selectedSession: TerminalSession? {
        selectedTab as? TerminalSession
    }

    /// The session new tabs inherit their directory from (the selected one, or the last terminal).
    private var directorySource: TerminalSession? {
        selectedSession ?? tabs.compactMap { $0 as? TerminalSession }.last
    }

    func addTab(directory: String, prefill: String? = nil) {
        let session = TerminalSession(snapshot: configStore.snapshot, directory: directory)
        session.onChange = { [weak self] in self?.refreshTabs() }
        session.onRequestNewTab = { [weak self, weak session] text in
            self?.addTab(directory: session?.currentDirectory ?? NSHomeDirectory(), prefill: text)
        }
        session.onRequestClose = { [weak self, weak session] in
            guard let self, let session else { return }
            self.closeTab(id: session.id)
        }
        insert(session)

        // Size the view before the shell starts so it gets the right winsize immediately.
        contentArea.layoutSubtreeIfNeeded()
        session.start()
        session.focus()
        if let prefill { session.view.inputArea.setText(prefill) }
        #if DEBUG
        if tabs.count == 1 { DebugDriver.runIfRequested(session: session) }
        #endif
    }

    /// Shows the Settings tab, creating it next to the current tab if needed.
    func openSettingsTab() {
        if let index = tabs.firstIndex(where: { $0 is SettingsTab }) {
            select(index: index)
            return
        }
        insert(SettingsTab(store: configStore))
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
        tabsModel.tabs = tabs.map { TabItem(id: $0.id, title: $0.title) }
        tabsModel.selectedID = selectedTab?.id
        if let directory = fileTreeSession?.currentDirectory {
            fileTree.setRoot(directory)
        }
        window?.title = selectedTab?.title ?? "Rune"
    }

    // MARK: - Menu actions (responder chain)

    @objc func newTab(_ sender: Any?) {
        addTab(directory: directorySource?.currentDirectory ?? NSHomeDirectory())
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = selectedTab {
            requestCloseTab(id: tab.id)
        }
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
        if show { host.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            width.animator().constant = show ? fileTreePreferredWidth : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            if !show { host.isHidden = true }
            if !show { self?.selectedTab?.focus() }
        })
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
