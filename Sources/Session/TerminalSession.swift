import AppKit
import RuneKit
import SwiftTerm

/// SwiftTerm view with hooks Rune needs.
final class RuneTerminalView: LocalProcessTerminalView {
    var onDataReceived: (() -> Void)?
    /// When set, user input is offered here instead of the PTY (used after the process exits).
    var inputInterceptor: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onDataReceived?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let inputInterceptor {
            inputInterceptor(data)
            return
        }
        super.send(source: source, data: data)
    }
}

/// One shell running in a PTY, plus the view that displays it.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        case notStarted
        case running
        case exited(ProcessExit?)
    }

    let id = UUID()
    let terminalView: RuneTerminalView
    let container: TerminalContainerView

    private(set) var state: State = .notStarted
    private(set) var currentDirectory: String
    private var startedAt = Date()
    private var sawOSC7 = false
    private var cwdPollScheduled = false
    private var lastSnapshot: ConfigSnapshot?

    /// Title or cwd changed.
    var onChange: (() -> Void)?
    /// The shell exited and the tab should close.
    var onRequestClose: (() -> Void)?

    private static let displayHost = HostIdentity.displayHostname()
    private static let userName = HostIdentity.userName()

    /// A shell that dies this quickly probably failed to start; keep its output visible.
    private static let earlyExitWindow: TimeInterval = 2

    init(snapshot: ConfigSnapshot, directory: String) {
        let config = snapshot.config
        let options = TerminalOptions(
            cursorStyle: config.cursorStyle.terminalStyle(blink: config.cursorBlink),
            scrollback: config.scrollback
        )
        terminalView = RuneTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: snapshot.font, options: options)
        container = TerminalContainerView(terminalView: terminalView)
        currentDirectory = directory
        super.init()

        terminalView.processDelegate = self
        terminalView.onDataReceived = { [weak self] in self?.scheduleCwdPoll() }
        apply(snapshot)
    }

    var title: String {
        TabTitle.make(
            user: Self.userName,
            host: Self.displayHost,
            path: currentDirectory,
            home: NSHomeDirectory()
        )
    }

    func apply(_ snapshot: ConfigSnapshot) {
        lastSnapshot = snapshot
        let config = snapshot.config
        let theme = snapshot.theme
        let view = terminalView

        if view.font != snapshot.font {
            view.font = snapshot.font
        }
        view.nativeBackgroundColor = theme.background.nsColor
        view.nativeForegroundColor = theme.foreground.nsColor
        view.caretColor = theme.cursor.nsColor
        view.selectedTextBackgroundColor = theme.selectionBackground.nsColor
        view.selectedTextForegroundColor = theme.selectionForeground.nsColor
        view.installColors(theme.ansi.map(\.terminalColor))
        view.optionAsMetaKey = config.optionAsMeta
        view.getTerminal().setCursorStyle(config.cursorStyle.terminalStyle(blink: config.cursorBlink))

        container.background = theme.background.nsColor
        container.padding = NSEdgeInsets(top: config.paddingY, left: config.paddingX, bottom: config.paddingY, right: config.paddingX)
    }

    func start(snapshot: ConfigSnapshot) {
        let shell = ShellResolver.resolve(
            configured: snapshot.config.shell,
            environment: ProcessInfo.processInfo.environment,
            accountShell: ShellResolver.accountShell()
        )
        let directory = FileManager.default.fileExists(atPath: currentDirectory) ? currentDirectory : NSHomeDirectory()
        currentDirectory = directory
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let env = ShellEnvironment.build(
            inherited: ProcessInfo.processInfo.environment,
            currentDirectory: directory,
            appVersion: version
        )

        terminalView.inputInterceptor = nil
        startedAt = Date()
        state = .running
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: ShellEnvironment.toArray(env),
            execName: ShellResolver.loginArgv0(for: shell),
            currentDirectory: directory
        )
        onChange?()
    }

    func terminate() {
        guard state == .running else { return }
        state = .exited(nil)
        terminalView.onDataReceived = nil
        terminalView.terminate()
    }

    // MARK: - cwd tracking

    /// Without shell integration (Phase 2) the shell doesn't report its cwd, so read it
    /// from the kernel shortly after output arrives.
    private func scheduleCwdPoll() {
        guard !sawOSC7, !cwdPollScheduled else { return }
        cwdPollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.cwdPollScheduled = false
            guard self.state == .running,
                  let pid = self.terminalView.process?.shellPid,
                  let path = ProcessInfoReader.currentDirectory(of: pid)
            else { return }
            self.updateDirectory(path)
        }
    }

    private func updateDirectory(_ path: String) {
        guard path != currentDirectory else { return }
        currentDirectory = path
        onChange?()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let path = TabTitle.pathFromOSC7(directory) else { return }
        sawOSC7 = true
        updateDirectory(path)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // We asked for this (tab/window closed); nothing to show.
        if case .exited = state { return }

        let exit = exitCode.map(ProcessExit.init(waitStatus:))
        state = .exited(exit)
        let lifetime = Date().timeIntervalSince(startedAt)

        if lifetime >= Self.earlyExitWindow {
            onRequestClose?()
            return
        }

        let reason: String
        switch exit {
        case .exited(let code)?: reason = "exited with code \(code)"
        case .signaled(let signal)?: reason = "was killed by signal \(signal)"
        case nil: reason = "stopped (I/O error)"
        }
        let message = "\r\n\u{1b}[2m[Process \(reason). Press Return to restart or ⌘W to close.]\u{1b}[0m\r\n"
        terminalView.feed(text: message)
        terminalView.inputInterceptor = { [weak self] data in
            guard let self, data.contains(13) else { return }
            self.restartAfterExit()
        }
    }

    private func restartAfterExit() {
        guard let snapshot = lastSnapshot else { return }
        terminalView.getTerminal().resetToInitialState()
        start(snapshot: snapshot)
    }
}
