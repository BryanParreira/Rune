import AppKit
import Combine
import RuneKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configStore: ConfigStore?
    private var windowControllers: [MainWindowController] = []
    private var shortcutObserver: AnyCancellable?
    /// Folders handed to us (Finder, `rune` CLI) before launch finished.
    private var pendingDirectories: [String] = []
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessLimits.logUncaughtExceptions()
        ProcessLimits.raiseOpenFileLimit()
        let info = Bundle.main.infoDictionary ?? [:]
        Log.app.notice("Rune \(info["CFBundleShortVersionString"] as? String ?? "?", privacy: .public) (\(info["CFBundleVersion"] as? String ?? "?", privacy: .public)) launched")
        NSApp.mainMenu = MainMenu.build()
        UpdateController.shared.start()
        let store = ConfigStore()
        configStore = store
        ConfigStore.current = store
        AIService.shared.start(store: store)
        RecallService.shared.prune(keepingDays: store.snapshot.config.recallDays)
        // Completions for hundreds of tools (about 1 MB compressed), off the main thread.
        if let specs = Bundle.main.url(forResource: "fig-specs", withExtension: "deflate", subdirectory: "Completions") {
            DispatchQueue.global(qos: .utility).async { CompletionLibrary.shared.load(contentsOf: specs) }
        }
        Self.adoptNewDesignDefaults(store)
        CommandNotifier.shared.start()
        CommandNotifier.shared.onOpen = { [weak self] sessionID in
            _ = self?.windowControllers.first { $0.reveal(sessionID: sessionID) }
        }
        didFinishLaunching = true
        setUpGlobalHotKey(store)
        setUpDockIcon(store)
        NSApp.servicesProvider = self

        // Opened on a specific folder (Finder, `rune`, --cwd): open just that.
        let openedOnFolder = !pendingDirectories.isEmpty || CommandLine.arguments.contains("--cwd")
        if pendingDirectories.isEmpty { pendingDirectories = [Self.launchDirectory()] }
        if Self.launchedAsLoginItem, !openedOnFolder, !OnboardingWindowController.needsOnboarding {
            // Started at login: stay in the background until the hotkey (or the Dock) asks,
            // with a shell already started so the first press opens a ready prompt.
            startupWindowsPending = true
            SessionPool.shared.scheduleRefill(snapshot: store.snapshot)
            return
        }
        openStartupWindows(openedOnFolder: openedOnFolder)
    }

    /// Set when launched at login: the first window opens on demand.
    private var startupWindowsPending = false

    private func openStartupWindows(openedOnFolder: Bool) {
        startupWindowsPending = false
        guard let store = configStore else { return }
        if OnboardingWindowController.needsOnboarding, !Self.isAutomatedRun {
            // First launch: the guide comes first; the terminal opens when it closes.
            isFirstRunOnboarding = true
            showOnboarding(nil)
            onboardingController?.onClose = { [weak self] in
                guard let self else { return }
                self.isFirstRunOnboarding = false
                self.openPendingDirectories()
            }
        } else if !openedOnFolder, store.snapshot.config.restoreSession, !Self.isAutomatedRun || Self.usesTestSessionFile,
                  let saved = SessionFile.load() {
            pendingDirectories.removeAll()
            for window in saved.windows { makeWindow(directory: NSHomeDirectory(), restoring: window) }
            if windowControllers.isEmpty { openPendingDirectories() }
        } else {
            openPendingDirectories()
        }
        NSApp.activate()
    }

    /// macOS started Rune as a login item.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: - Global hotkey

    private var hotKeyObserver: AnyCancellable?

    private func setUpGlobalHotKey(_ store: ConfigStore) {
        guard !Self.isAutomatedRun else { return }
        GlobalHotKey.shared.onPress = { [weak self] in self?.toggleFromHotKey() }
        GlobalHotKey.shared.register(store.snapshot.config.globalHotkey)
        MainMenu.applyShortcuts(store.snapshot.config.keyboardShortcuts)
        shortcutObserver = store.$snapshot
            .map(\.config.keyboardShortcuts)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { MainMenu.applyShortcuts($0) }
        hotKeyObserver = store.$snapshot
            .map(\.config.globalHotkey)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { GlobalHotKey.shared.register($0) }
    }

    /// The hotkey: bring Rune forward (opening a window if needed), or hide it when it's
    /// already in front.
    private func toggleFromHotKey() {
        if NSApp.isActive, NSApp.keyWindow?.windowController is MainWindowController {
            NSApp.hide(nil)
            return
        }
        NSApp.unhide(nil)
        if startupWindowsPending {
            openStartupWindows(openedOnFolder: false)
        } else if let window = frontController()?.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            newWindow(nil)
        }
        NSApp.activate()
    }

    // MARK: - Dock icon

    private var dockIconObserver: AnyCancellable?
    private var statusItem: NSStatusItem?

    private func setUpDockIcon(_ store: ConfigStore) {
        guard !Self.isAutomatedRun else { return }
        dockIconObserver = store.$snapshot
            .map(\.config.showDockIcon)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyDockIcon(shown: $0) }
    }

    /// Hidden: Rune leaves the Dock and ⌘-Tab and lives behind the global hotkey and a menu-bar
    /// icon (so it's always reachable, even with the hotkey turned off).
    private func applyDockIcon(shown: Bool) {
        if shown {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Rune")
            item.button?.image?.isTemplate = true
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "Show Rune") { [weak self] in self?.showFromMenuBar() })
            menu.addItem(ClosureMenuItem(title: "New Window") { [weak self] in
                self?.newWindow(nil)
                NSApp.activate()
            })
            menu.addItem(ClosureMenuItem(title: "Settings…") { [weak self] in self?.openSettings(nil) })
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit Rune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
            item.menu = menu
            statusItem = item
        }
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
            // Leaving the Dock deactivates the app; keep the window the user was in in front.
            DispatchQueue.main.async { NSApp.activate() }
        }
    }

    private func showFromMenuBar() {
        NSApp.unhide(nil)
        if startupWindowsPending {
            openStartupWindows(openedOnFolder: false)
        } else if let window = frontController()?.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            newWindow(nil)
        }
        NSApp.activate()
    }

    // MARK: - Session saving

    private var saveWork: DispatchWorkItem?

    /// Saves the open windows shortly after the latest change.
    private func scheduleSessionSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func saveSession() {
        saveWork?.cancel()
        // Test runs share this Mac's files; they must never replace the user's session.
        guard !Self.isAutomatedRun || Self.usesTestSessionFile, !isFirstRunOnboarding else { return }
        SessionFile.save(SavedSession(windows: windowControllers.map(\.savedState).filter { !$0.tabs.isEmpty }))
    }

    private func openPendingDirectories() {
        let directories = pendingDirectories
        pendingDirectories.removeAll()
        directories.forEach(open(directory:))
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "rune" { openRuneURL(url) }
        let directories = urls.compactMap(Self.directory(for:))
        guard didFinishLaunching, !isFirstRunOnboarding else {
            pendingDirectories.append(contentsOf: directories)
            return
        }
        directories.forEach(open(directory:))
        NSApp.activate()
    }

    /// `rune://open?dir=~/project&command=npm%20test` opens a tab in that folder with the
    /// command typed in the input, for launchers like Raycast and Alfred. It never runs the
    /// command: any web page can open a URL.
    private func openRuneURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let directory = value("dir").map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
        let command = value("command")
        guard didFinishLaunching, !isFirstRunOnboarding else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openRuneURL(url) }
            return
        }
        openTab(directory: directory, command: command, run: false)
        NSApp.activate()
    }

    // MARK: - Problem reports

    @objc func reportProblem(_ sender: Any?) {
        let sessions = windowControllers.flatMap(\.allSessions)
        guard let configStore, let folder = ProblemReport.create(sessions: sessions, config: configStore) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        let alert = NSAlert()
        alert.messageText = "Your report is ready"
        alert.informativeText = "It's in the folder that just opened: Rune's version, your Mac, settings (with secrets removed), Rune's log from the last hour and any recent crash reports. Nothing was sent anywhere. Look it over, then attach it to an issue if you'd like help."
        alert.addButton(withTitle: "Open an Issue on GitHub")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn, let url = ProblemReport.issueURL(summary: ProblemReport.summary(sessions: sessions)) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Automation (Shortcuts, URLs)

    /// A new tab in `directory` (a folder that doesn't exist falls back to home), with
    /// `command` in its input, run once the shell is ready if `run` is set.
    @discardableResult
    func openTab(directory: String, command: String?, run: Bool) -> TerminalSession? {
        var isDirectory: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
            ? directory : NSHomeDirectory()
        if frontController() == nil { makeWindow(directory: folder) } else { open(directory: folder) }
        guard let controller = frontController(), let session = controller.selectedSession else { return nil }
        controller.window?.makeKeyAndOrderFront(nil)
        if let command, !command.isEmpty {
            if run { session.runWhenReady(command) } else { session.view.inputArea.setText(command) }
        }
        return session
    }

    /// The pane the user is looking at in the frontmost window.
    var frontSession: TerminalSession? { frontController()?.selectedSession }

    // MARK: - Finder services

    /// Services > New Rune Tab Here, on folders selected in Finder.
    @objc func newTabHere(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        openFromService(pasteboard, newWindow: false)
    }

    /// Services > New Rune Window Here.
    @objc func newWindowHere(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        openFromService(pasteboard, newWindow: true)
    }

    private func openFromService(_ pasteboard: NSPasteboard, newWindow: Bool) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let directories = urls.compactMap(Self.directory(for:))
        guard !directories.isEmpty else { return }
        guard didFinishLaunching, !isFirstRunOnboarding else {
            pendingDirectories.append(contentsOf: directories)
            return
        }
        // Started at login with no window yet: this is the window the user asked for.
        startupWindowsPending = false
        for directory in directories {
            if newWindow { makeWindow(directory: directory) } else { open(directory: directory) }
        }
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if startupWindowsPending {
            openStartupWindows(openedOnFolder: false)
            return true
        }
        if isFirstRunOnboarding {
            onboardingController?.window?.makeKeyAndOrderFront(nil)
            return true
        }
        if !flag {
            if let window = windowControllers.first?.window {
                window.makeKeyAndOrderFront(nil)
            } else {
                newWindow(nil)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Asks before quitting while programs are running in any tab.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveSession()
        let programs = windowControllers.flatMap(\.runningPrograms)
        guard !programs.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Rune?"
        alert.informativeText = MainWindowController.describe(programs) + " Quitting will stop \(programs.count == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Windows

    /// Opens `directory` as a new tab in the frontmost window, or a new window if there is none.
    private func open(directory: String) {
        if let controller = frontController() {
            controller.addTab(directory: directory)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            makeWindow(directory: directory)
        }
    }

    private func frontController() -> MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        return windowControllers.last
    }

    /// The window a tab is in (for a tab dragged between windows).
    func controller(owningTab id: UUID) -> MainWindowController? {
        windowControllers.first { $0.containsTab(id: id) }
    }

    /// A new window holding a tab taken out of another one.
    func newWindow(adopting tab: TabContent, cascadingFrom source: NSWindow?) {
        makeWindow(directory: NSHomeDirectory(), adopting: tab)
        if let source, let window = windowControllers.last?.window {
            window.setFrameTopLeftPoint(source.cascadeTopLeft(from: NSPoint(x: source.frame.minX, y: source.frame.maxY)))
        }
    }

    private func makeWindow(directory: String, restoring saved: SavedSession.Window? = nil, adopting tab: TabContent? = nil) {
        guard let configStore else { return }
        let controller = MainWindowController(configStore: configStore, directory: directory, restoring: saved, adopting: tab)
        controller.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
            // Unless the app is quitting (already saved), closing a window updates the session.
            if NSApp.isRunning, self?.isTerminating == false { self?.scheduleSessionSave() }
        }
        controller.onStateChange = { [weak self] in self?.scheduleSessionSave() }
        windowControllers.append(controller)
        if saved?.frame == nil, windowControllers.count > 1, let previous = windowControllers.dropLast().last?.window {
            controller.window?.setFrameTopLeftPoint(
                previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
            )
        }
        controller.showWindow(nil)
    }

    // MARK: - Launch layouts

    var layoutStore: LaunchLayoutStore? { configStore.map { LaunchLayoutStore(paths: $0.paths) } }

    /// Opens a saved layout in a new window and starts its pane commands.
    func openLayout(_ layout: LaunchLayout) {
        let home = NSHomeDirectory()
        let tabs = layout.tabs.map { tab in
            SavedSession.Tab.terminal(tab.root.layout(home: home, fileExists: { FileManager.default.fileExists(atPath: $0) }), style: tab.style)
        }
        guard !tabs.isEmpty else { return }
        makeWindow(directory: home, restoring: SavedSession.Window(frame: nil, selectedTab: 0, tabs: tabs))
        windowControllers.last?.runStartCommands(layout.tabs.map(\.root.commands))
        NSApp.activate()
    }

    /// Shell > Open Layout > (a layout).
    @objc func openLayoutFromMenu(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? URL,
              let entry = layoutStore?.loadAll().first(where: { $0.file == file }) else { return }
        openLayout(entry.layout)
    }

    @objc func showLayoutsFolder(_ sender: Any?) {
        guard let directory = layoutStore?.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    // MARK: - Menu actions (reached when no window handles them)

    @objc func newWindow(_ sender: Any?) {
        let directory = frontController()?.selectedSession?.currentDirectory ?? NSHomeDirectory()
        makeWindow(directory: directory)
    }

    /// ⇧⌘T with no window open: reopen the last closed tab in a new window.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let tab = ClosedTabs.shared.pop() else { NSSound.beep(); return }
        makeWindow(directory: NSHomeDirectory(), restoring: SavedSession.Window(frame: nil, selectedTab: 0, tabs: [tab]))
        NSApp.activate()
    }

    @objc func newTab(_ sender: Any?) {
        makeWindow(directory: NSHomeDirectory())
    }

    private var isTerminating = false

    /// One time, when updating to the Paper design: configs still on the old defaults
    /// (every install had "rune-dark" + "SF Mono") move to the new ones. Anyone can switch
    /// back in Settings (the old look is "Rune Classic").
    private static func adoptNewDesignDefaults(_ store: ConfigStore) {
        let key = "RuneDesignDefaultsVersion"
        guard !isAutomatedRun, UserDefaults.standard.integer(forKey: key) < 1 else { return }
        UserDefaults.standard.set(1, forKey: key)
        let config = store.snapshot.config
        if config.theme == "rune-dark" { store.write(key: "theme", value: "paper") }
        if config.fontFamily == "SF Mono" { store.write(key: "fontFamily", value: "JetBrains Mono") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        Log.app.notice("Rune quit")
    }

    private var onboardingController: OnboardingWindowController?
    /// True while the first-launch guide is open and no terminal window exists yet.
    private var isFirstRunOnboarding = false

    /// Debug test runs share this Mac's preferences; they must not show or complete onboarding.
    static var isAutomatedRun: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["RUNE_DEBUG_SCRIPT"] != nil
        #else
        return false
        #endif
    }

    private static var usesTestSessionFile: Bool {
        #if DEBUG
        return SessionFile.testOverride != nil
        #else
        return false
        #endif
    }

    @objc func showOnboarding(_ sender: Any?) {
        guard let configStore else { return }
        // Reopening from the menu starts over at the first step.
        if onboardingController?.window?.isVisible != true {
            onboardingController = OnboardingWindowController(store: configStore)
        }
        onboardingController?.showWindow(nil)
        onboardingController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Reached only when no Rune window is key (the window controller handles it otherwise).
    @objc func openSettings(_ sender: Any?) {
        if frontController() == nil {
            makeWindow(directory: NSHomeDirectory())
        }
        frontController()?.openSettingsTab()
        frontController()?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func openConfig(_ sender: Any?) {
        guard let configStore else { return }
        Self.openInEditor(configStore.paths.configFile)
    }

    @objc func revealConfigFolder(_ sender: Any?) {
        guard let configStore else { return }
        NSWorkspace.shared.activateFileViewerSelecting([configStore.paths.configFile])
    }

    @objc func reloadConfig(_ sender: Any?) {
        configStore?.reload()
    }

    // MARK: - Helpers

    /// Opens a text file in the user's default editor for it, falling back to TextEdit.
    static func openInEditor(_ url: URL) {
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: url) != nil {
            workspace.open(url)
            return
        }
        if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// `--cwd <path>` on the command line, else $HOME.
    private static func launchDirectory() -> String {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--cwd"), args.indices.contains(flag + 1),
           let dir = directory(for: URL(fileURLWithPath: args[flag + 1])) {
            return dir
        }
        return NSHomeDirectory()
    }

    private static func directory(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? url.path : url.deletingLastPathComponent().path
    }
}
