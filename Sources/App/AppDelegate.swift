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
        configStore = ConfigStore()
        didFinishLaunching = true

        let initial = pendingDirectories.isEmpty ? [Self.launchDirectory()] : pendingDirectories
        pendingDirectories.removeAll()
        for directory in initial {
            open(directory: directory)
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let directories = urls.compactMap(Self.directory(for:))
        guard didFinishLaunching else {
            pendingDirectories.append(contentsOf: directories)
            return
        }
        directories.forEach(open(directory:))
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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
