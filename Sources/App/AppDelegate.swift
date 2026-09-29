import AppKit
import RuneKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configStore: ConfigStore?
    private var windowControllers: [MainWindowController] = []
    /// Folders handed to us (Finder, `rune` CLI) before launch finished.
    private var pendingDirectories: [String] = []
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        UpdateController.shared.start()
        let store = ConfigStore()
        configStore = store
        ConfigStore.current = store
        AIService.shared.start(store: store)
        CommandNotifier.shared.start()
        CommandNotifier.shared.onOpen = { [weak self] sessionID in
            _ = self?.windowControllers.first { $0.reveal(sessionID: sessionID) }
        }
        didFinishLaunching = true

        if pendingDirectories.isEmpty { pendingDirectories = [Self.launchDirectory()] }
        if OnboardingWindowController.needsOnboarding, !Self.isAutomatedRun {
            // First launch: the guide comes first; the terminal opens when it closes.
            isFirstRunOnboarding = true
            showOnboarding(nil)
            onboardingController?.onClose = { [weak self] in
                guard let self else { return }
                self.isFirstRunOnboarding = false
                self.openPendingDirectories()
            }
        } else {
            openPendingDirectories()
        }
        NSApp.activate()
    }

    private func openPendingDirectories() {
        let directories = pendingDirectories
        pendingDirectories.removeAll()
        directories.forEach(open(directory:))
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let directories = urls.compactMap(Self.directory(for:))
        guard didFinishLaunching, !isFirstRunOnboarding else {
            pendingDirectories.append(contentsOf: directories)
            return
        }
        directories.forEach(open(directory:))
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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

    private func makeWindow(directory: String) {
        guard let configStore else { return }
        let controller = MainWindowController(configStore: configStore, directory: directory)
        controller.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        if windowControllers.count > 1, let previous = windowControllers.dropLast().last?.window {
            controller.window?.setFrameTopLeftPoint(
                previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
            )
        }
        controller.showWindow(nil)
    }

    // MARK: - Menu actions (reached when no window handles them)

    @objc func newWindow(_ sender: Any?) {
        let directory = frontController()?.selectedSession?.currentDirectory ?? NSHomeDirectory()
        makeWindow(directory: directory)
    }

    @objc func newTab(_ sender: Any?) {
        makeWindow(directory: NSHomeDirectory())
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
