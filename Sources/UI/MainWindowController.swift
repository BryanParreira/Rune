import AppKit
import Combine
import RuneKit
import SwiftUI

/// One Rune window: custom tab bar in the titlebar, config warning strip, and the active terminal.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let tabBarHeight: CGFloat = 38

    private let configStore: ConfigStore
    private var sessions: [TerminalSession] = []
    private var selectedIndex = 0
    private var cancellables: Set<AnyCancellable> = []

    private let tabsModel: TabsModel
    private let warningModel: WarningModel
    private let terminalArea = NSView()

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

        for view in [tabBar, banner, terminalArea] {
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

            terminalArea.topAnchor.constraint(equalTo: banner.bottomAnchor),
            terminalArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window.contentView = root
        TrafficLights.position(in: window, barHeight: Self.tabBarHeight)
    }

    private func wireModels() {
        tabsModel.onSelect = { [weak self] id in self?.selectTab(id: id) }
        tabsModel.onClose = { [weak self] id in self?.closeTab(id: id) }
        tabsModel.onNew = { [weak self] in self?.newTab(nil) }
        warningModel.onOpenConfig = { [weak self] in
            guard let self else { return }
            AppDelegate.openInEditor(self.configStore.paths.configFile)
        }
    }

    private func applySnapshot(_ snapshot: ConfigSnapshot) {
        let palette = ChromePalette(theme: snapshot.theme)
        tabsModel.palette = palette
        warningModel.palette = palette
        if warningModel.warnings != snapshot.warnings {
            warningModel.warnings = snapshot.warnings
            warningModel.dismissed = false
        }
        window?.backgroundColor = palette.background
        window?.contentView?.layer?.backgroundColor = palette.background.cgColor
        for session in sessions {
            session.apply(snapshot)
        }
    }

    // MARK: - Tabs

    var selectedSession: TerminalSession? {
        sessions.indices.contains(selectedIndex) ? sessions[selectedIndex] : nil
    }

    func addTab(directory: String) {
        let snapshot = configStore.snapshot
        let session = TerminalSession(snapshot: snapshot, directory: directory)
        session.onChange = { [weak self] in self?.refreshTabs() }
        session.onRequestClose = { [weak self, weak session] in
            guard let self, let session else { return }
            self.closeTab(id: session.id)
        }

        let container = session.container
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        terminalArea.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: terminalArea.topAnchor),
            container.leadingAnchor.constraint(equalTo: terminalArea.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: terminalArea.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: terminalArea.bottomAnchor),
        ])

        let insertAt = sessions.isEmpty ? 0 : selectedIndex + 1
        sessions.insert(session, at: insertAt)
        select(index: insertAt)

        // Size the view before the shell starts so it gets the right winsize immediately.
        terminalArea.layoutSubtreeIfNeeded()
        session.start(snapshot: snapshot)
    }

    private func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedIndex = index
        for (i, session) in sessions.enumerated() {
            session.container.isHidden = i != index
        }
        refreshTabs()
        if let session = selectedSession {
            window?.makeFirstResponder(session.terminalView)
        }
    }

    private func selectTab(id: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            select(index: index)
        }
    }

    private func closeTab(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.onChange = nil
        session.onRequestClose = nil
        session.terminate()
        session.container.removeFromSuperview()

        if sessions.isEmpty {
            window?.close()
            return
        }
        let next = index < selectedIndex || selectedIndex >= sessions.count ? max(0, selectedIndex - 1) : selectedIndex
        select(index: min(next, sessions.count - 1))
    }

    private func refreshTabs() {
        tabsModel.tabs = sessions.map { TabItem(id: $0.id, title: $0.title) }
        tabsModel.selectedID = selectedSession?.id
        window?.title = selectedSession?.title ?? "Rune"
    }

    // MARK: - Menu actions (responder chain)

    @objc func newTab(_ sender: Any?) {
        addTab(directory: selectedSession?.currentDirectory ?? NSHomeDirectory())
    }

    @objc func closeTab(_ sender: Any?) {
        if let session = selectedSession {
            closeTab(id: session.id)
        }
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // Tag 1–8 select that tab; 9 selects the last tab, like browsers.
        let index = sender.tag == 9 ? sessions.count - 1 : sender.tag - 1
        select(index: index)
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard !sessions.isEmpty else { return }
        select(index: (selectedIndex + 1) % sessions.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard !sessions.isEmpty else { return }
        select(index: (selectedIndex - 1 + sessions.count) % sessions.count)
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
    }

    func windowWillClose(_ notification: Notification) {
        cancellables.removeAll()
        for session in sessions {
            session.onRequestClose = nil
            session.terminate()
        }
        sessions.removeAll()
        onClose?(self)
    }
}
