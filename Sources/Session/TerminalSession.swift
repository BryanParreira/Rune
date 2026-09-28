import AppKit
import RuneKit
import SwiftTerm

/// SwiftTerm view with the hooks Rune needs.
final class RuneTerminalView: LocalProcessTerminalView {
    var onDataReceived: (() -> Void)?
    var onScrolled: (() -> Void)?
    var onBufferSwitched: (() -> Void)?
    /// When set, keyboard input is offered here instead of the PTY. Return true to consume it.
    var inputInterceptor: ((ArraySlice<UInt8>) -> Bool)?
    /// Supplies a context menu for a click location (block actions).
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?

    private var bypassInterceptor = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onDataReceived?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !bypassInterceptor, let inputInterceptor, inputInterceptor(data) {
            return
        }
        super.send(source: source, data: data)
    }

    /// Sends bytes to the shell regardless of input routing (commands from the editor).
    func sendToShell(_ bytes: [UInt8]) {
        bypassInterceptor = true
        send(data: bytes[...])
        bypassInterceptor = false
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScrolled?()
    }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onBufferSwitched?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuProvider?(point) ?? super.menu(for: event)
    }
}

/// One shell running in a PTY: process lifecycle, shell integration, blocks, and input routing.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        case notStarted
        case running
        case exited(ProcessExit?)
    }

    let id = UUID()
    let terminalView: RuneTerminalView
    let view: SessionView
    let tracker: BlockTracker

    private(set) var state: State = .notStarted
    private(set) var currentDirectory: String
    private(set) var gitBranch: String?
    private(set) var integration: IntegrationState = .pending
    private(set) var mode: InputMode = .editor
    /// Block highlighted by Cmd-Up/Down.
    private(set) var selectedBlockID: Int?

    /// Title, cwd or mode changed.
    var onChange: (() -> Void)?
    /// The shell exited and the tab should close.
    var onRequestClose: (() -> Void)?

    private var snapshot: ConfigSnapshot
    private var startedAt = Date()
    private var sawOSC7 = false
    private var cwdPollScheduled = false
    private var integrationTimeout: DispatchWorkItem?
    private var historyNavigator = HistoryNavigator()
    /// Buffer lines backing the rows the tracker knows about, so rows can be re-found after
    /// the terminal reflows on resize.
    private var anchorLines: [Int: BufferLine] = [:]
    private var lastColumns = 0
    private var liveTimer: Timer?
    /// Fixed per shell launch: the integration sets up the prompt for one style or the other.
    private(set) var typeInShell = false

    private static let displayHost = HostIdentity.displayHostname()
    private static let userName = HostIdentity.userName()
    /// A shell that dies this quickly probably failed to start; keep its output visible.
    private static let earlyExitWindow: TimeInterval = 2
    /// How long to wait for the integration to say hello before treating the shell as plain.
    private static let integrationGracePeriod: TimeInterval = 6

    init(snapshot: ConfigSnapshot, directory: String) {
        self.snapshot = snapshot
        let config = snapshot.config
        let options = TerminalOptions(
            cursorStyle: config.cursorStyle.terminalStyle(blink: config.cursorBlink),
            scrollback: config.scrollback
        )
        terminalView = RuneTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: snapshot.font, options: options)
        tracker = BlockTracker(host: Self.displayHost)
        currentDirectory = directory
        view = SessionView(terminalView: terminalView)
        super.init()

        view.session = self
        terminalView.processDelegate = self
        terminalView.getTerminal().semanticPromptClickBehavior = .disabled
        terminalView.onDataReceived = { [weak self] in self?.handleDataReceived() }
        terminalView.onScrolled = { [weak self] in self?.view.blocksDidChange() }
        terminalView.onBufferSwitched = { [weak self] in self?.updateMode() }
        terminalView.inputInterceptor = { [weak self] data in self?.intercept(data) ?? false }
        terminalView.contextMenuProvider = { [weak self] point in self?.contextMenu(atTerminalPoint: point) }
        installOSCHandlers()
        apply(snapshot)
        HistoryStore.shared.loadIfNeeded()
    }

    var title: String {
        TabTitle.make(user: Self.userName, host: Self.displayHost, path: currentDirectory, home: NSHomeDirectory())
    }

    var geometry: BufferGeometry {
        BufferGeometry(terminal: terminalView.getTerminal(), view: terminalView)
    }

    var config: RuneConfig { snapshot.config }
    var palette: ChromePalette { ChromePalette(theme: snapshot.theme) }

    // MARK: - Appearance

    func apply(_ snapshot: ConfigSnapshot) {
        self.snapshot = snapshot
        let config = snapshot.config
        let theme = snapshot.theme
        let tv = terminalView

        if tv.font != snapshot.font { tv.font = snapshot.font }
        if abs(tv.lineSpacing - CGFloat(config.lineHeight)) > 0.001 { tv.lineSpacing = CGFloat(config.lineHeight) }
        tv.nativeBackgroundColor = theme.background.nsColor
        tv.nativeForegroundColor = theme.foreground.nsColor
        tv.caretColor = theme.cursor.nsColor
        tv.selectedTextBackgroundColor = theme.selectionBackground.nsColor
        tv.selectedTextForegroundColor = theme.selectionForeground.nsColor
        tv.installColors(theme.ansi.map(\.terminalColor))
        tv.optionAsMetaKey = config.optionAsMeta
        tv.getTerminal().setCursorStyle(config.cursorStyle.terminalStyle(blink: config.cursorBlink))
        view.apply(snapshot)
    }

    // MARK: - Process

    func start() {
        let config = snapshot.config
        let shell = ShellResolver.resolve(
            configured: config.shell,
            environment: ProcessInfo.processInfo.environment,
            accountShell: ShellResolver.accountShell()
        )
        let directory = FileManager.default.fileExists(atPath: currentDirectory) ? currentDirectory : NSHomeDirectory()
        currentDirectory = directory
        refreshGitBranch()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var env = ShellEnvironment.build(inherited: ProcessInfo.processInfo.environment, currentDirectory: directory, appVersion: version)

        typeInShell = config.inputMode == .shell
        if ShellResolver.isZsh(shell), let integrationDir = Self.zshIntegrationDirectory() {
            ShellEnvironment.addZshIntegration(to: &env, integrationDirectory: integrationDir,
                                               honorPrompt: config.honorPrompt, typeInShell: typeInShell)
            integration = .pending
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.integration == .pending else { return }
                self.integration = .unavailable
                self.updateMode()
            }
            integrationTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.integrationGracePeriod, execute: timeout)
        } else {
            integration = .unavailable
        }

        startedAt = Date()
        state = .running
        lastColumns = terminalView.getTerminal().cols
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: ShellEnvironment.toArray(env),
            execName: ShellResolver.loginArgv0(for: shell),
            currentDirectory: directory
        )
        updateMode()
        onChange?()
    }

    private static func zshIntegrationDirectory() -> String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("ShellIntegration/zsh", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent(".zshenv").path)
        else { return nil }
        return dir.path
    }

    func terminate() {
        integrationTimeout?.cancel()
        liveTimer?.invalidate()
        guard state == .running else { return }
        state = .exited(nil)
        terminalView.onDataReceived = nil
        terminalView.terminate()
    }

    // MARK: - Commands from the input editor

    /// Runs `command` in the shell (Enter in the editor).
    func submit(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state == .running else { return }
        HistoryStore.shared.append(trimmed)
        historyNavigator.reset()
        selectedBlockID = nil
        view.dismissWelcomeForSession()

        var bytes: [UInt8] = []
        if terminalView.getTerminal().bracketedPasteMode {
            // Paste mode keeps multi-line commands intact until the final Return.
            bytes += Array("\u{1b}[200~".utf8) + Array(trimmed.utf8) + Array("\u{1b}[201~".utf8)
        } else {
            bytes += Array(trimmed.replacingOccurrences(of: "\n", with: " ").utf8)
        }
        bytes.append(13)
        terminalView.sendToShell(bytes)
    }

    func historyOlder(current: String) -> String? {
        historyNavigator.older(in: HistoryStore.shared.history, current: current)
    }

    func historyNewer() -> String? {
        historyNavigator.newer(in: HistoryStore.shared.history)
    }

    func resetHistoryNavigation() {
        historyNavigator.reset()
    }

    func complete(text: String, cursor: Int) -> PathCompletion.Result? {
        PathCompletion.complete(text: text, cursor: cursor, cwd: currentDirectory, home: NSHomeDirectory())
    }

    /// Ctrl-D on an empty editor.
    func sendEOF() {
        terminalView.sendToShell([4])
    }

    /// Cmd-K: clears output and blocks, then lets the shell redraw its prompt.
    func clearScreen() {
        tracker.removeAll()
        anchorLines.removeAll()
        selectedBlockID = nil
        terminalView.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        if mode == .editor, integration == .active {
            terminalView.sendToShell([12]) // Ctrl-L: the shell redraws its (empty) prompt
        }
        view.blocksDidChange()
    }

    func interrupt() {
        terminalView.sendToShell([3])
    }

    // MARK: - Blocks

    func selectAdjacentBlock(previous: Bool) {
        let blocks = tracker.blocks
        guard !blocks.isEmpty else { return }
        let index: Int
        if let selectedBlockID, let current = blocks.firstIndex(where: { $0.id == selectedBlockID }) {
            index = previous ? max(0, current - 1) : current + 1
        } else {
            index = previous ? blocks.count - 1 : blocks.count
        }
        guard index < blocks.count else {
            // Past the newest block: back to the input.
            selectedBlockID = nil
            terminalView.scrollTo(row: Int.max)
            view.blocksDidChange()
            view.focusPreferredResponder()
            return
        }
        let block = blocks[index]
        selectedBlockID = block.id
        terminalView.scrollTo(row: max(0, block.headerRow - geometry.linesTrimmed))
        view.blocksDidChange()
    }

    func clearBlockSelection() {
        guard selectedBlockID != nil else { return }
        selectedBlockID = nil
        view.blocksDidChange()
    }

    func commandText(of block: Block) -> String {
        if !block.command.isEmpty { return block.command }
        let last = max(block.commandRow, block.outputStartRow - 1)
        return geometry.text(rows: block.commandRow...last)
    }

    func outputText(of block: Block) -> String {
        let current = geometry.cursorPosition.row
        guard let rows = block.outputRows(currentRow: current) else { return "" }
        return geometry.text(rows: rows)
    }

    func copyCommand(_ block: Block) {
        copyToPasteboard(commandText(of: block))
    }

    func copyOutput(_ block: Block) {
        copyToPasteboard(outputText(of: block))
    }

    func rerun(_ block: Block) {
        guard mode == .editor else { return }
        submit(commandText(of: block))
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func contextMenu(atTerminalPoint point: NSPoint) -> NSMenu? {
        let row = geometry.row(atY: point.y)
        guard let index = tracker.blockIndex(containing: row, currentRow: geometry.cursorPosition.row) else { return nil }
        let block = tracker.blocks[index]
        let menu = NSMenu()
        menu.addItem(BlockMenuItem(title: "Copy Command", block: block) { [weak self] in self?.copyCommand($0) })
        menu.addItem(BlockMenuItem(title: "Copy Output", block: block) { [weak self] in self?.copyOutput($0) })
        let rerunItem = BlockMenuItem(title: "Re-run Command", block: block) { [weak self] in self?.rerun($0) }
        rerunItem.isEnabled = mode == .editor
        menu.addItem(rerunItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        return menu
    }

    // MARK: - Shell integration

    private func installOSCHandlers() {
        let terminal = terminalView.getTerminal()
        // Keep SwiftTerm's own OSC 133 handling (it records prompt marks on lines) and
        // observe each mark first, while the cursor is where the shell put it.
        let builtIn133 = terminal.parser.oscHandlers[133]
        terminal.registerOscHandler(code: 133) { [weak self] data in
            if let text = String(bytes: data, encoding: .utf8), let mark = ShellMarkParser.parse133(text) {
                self?.handle(mark)
            }
            builtIn133?(data)
        }
        terminal.registerOscHandler(code: ShellMarkParser.runeOSC) { [weak self] data in
            if let text = String(bytes: data, encoding: .utf8), let mark = ShellMarkParser.parseRune(text) {
                self?.handle(mark)
            }
        }
    }

    private func handle(_ mark: ShellMark) {
        let terminal = terminalView.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        if integration != .active {
            integration = .active
            integrationTimeout?.cancel()
        }

        let cursor = geometry.cursorPosition
        let position = MarkPosition(row: cursor.row, column: cursor.column)
        if case .promptStart = mark, let last = tracker.blocks.last, position.row < last.headerRow {
            anchorLines.removeAll()
        }
        let changed = tracker.handle(mark, at: position)

        switch mark {
        case .promptStart, .commandStart, .outputStart, .commandFinished:
            if let line = terminal.getScrollInvariantLine(row: position.row) {
                anchorLines[position.row] = line
            }
            if case .commandFinished = mark, position.column == 0,
               let line = terminal.getScrollInvariantLine(row: position.row - 1) {
                anchorLines[position.row - 1] = line
            }
            pruneAnchors()
        case .currentDirectory(let path):
            sawOSC7 = true
            if path != currentDirectory {
                currentDirectory = path
                refreshGitBranch()
                view.contextDidChange()
                onChange?()
            }
        case .shellNames(let names):
            CommandCatalog.shared.setShellNames(Set(names))
            view.inputArea.refreshHighlighting()
        case .shellPath(let path):
            DispatchQueue.global(qos: .utility).async { [weak self] in
                CommandCatalog.shared.loadExecutables(path: path)
                DispatchQueue.main.async { self?.view.inputArea.refreshHighlighting() }
            }
        case .commandText, .integrationReady:
            break
        }

        if case .commandFinished = mark { refreshGitBranch() }
        if changed { view.blocksDidChange() }
        updateMode()
    }

    /// Keeps anchors only for rows that blocks still reference.
    private func pruneAnchors() {
        guard anchorLines.count > 64 else { return }
        var keep = Set<Int>()
        for block in tracker.blocks {
            keep.insert(block.headerRow)
            keep.insert(block.commandRow)
            keep.insert(block.outputStartRow)
            if let end = block.endRow { keep.insert(end) }
        }
        let current = geometry.cursorPosition.row
        anchorLines = anchorLines.filter { keep.contains($0.key) || $0.key >= current - 4 }
    }

    /// After a reflow, find each anchored line again and move blocks to its new row.
    private func remapAfterReflow() {
        guard !anchorLines.isEmpty else { return }
        let terminal = terminalView.getTerminal()
        let geometry = geometry
        let base = geometry.linesTrimmed
        let count = geometry.lineCount
        var rowOf: [ObjectIdentifier: Int] = [:]
        rowOf.reserveCapacity(count)
        for offset in 0..<count {
            if let line = terminal.getScrollInvariantLine(row: base + offset) {
                rowOf[ObjectIdentifier(line)] = base + offset
            }
        }
        let oldAnchors = anchorLines
        tracker.remapRows { old in
            oldAnchors[old].flatMap { rowOf[ObjectIdentifier($0)] }
        }
        var newAnchors: [Int: BufferLine] = [:]
        for (_, line) in oldAnchors {
            if let row = rowOf[ObjectIdentifier(line)] { newAnchors[row] = line }
        }
        anchorLines = newAnchors
        view.blocksDidChange()
    }

    private func refreshGitBranch() {
        let path = currentDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let branch = GitInfo.branch(at: path)
            DispatchQueue.main.async {
                guard let self, self.currentDirectory == path, self.gitBranch != branch else { return }
                self.gitBranch = branch
                self.view.contextDidChange()
            }
        }
    }

    // MARK: - Input routing

    private func updateMode() {
        let running = tracker.isCommandRunning
        if running, liveTimer == nil {
            // Live duration counter for the running block.
            liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.view.blocksDidChange()
            }
        } else if !running {
            liveTimer?.invalidate()
            liveTimer = nil
        }
        if case .exited = state { return }
        let newMode = InputRouter.mode(
            integration: integration,
            alternateScreen: terminalView.getTerminal().isCurrentBufferAlternate,
            commandRunning: running,
            typeInShell: typeInShell
        )
        guard newMode != mode else { return }
        mode = newMode
        view.modeDidChange()
        onChange?()
    }

    /// Keystrokes that reach the terminal view while the editor owns input are redirected
    /// to the editor (e.g. the user clicked the output to select text, then kept typing).
    private func intercept(_ data: ArraySlice<UInt8>) -> Bool {
        if case .exited = state {
            if data.contains(13) { restartAfterExit() }
            return true
        }
        guard mode == .editor else { return false }
        view.redirectToEditor(data)
        return true
    }

    // MARK: - Output

    private func handleDataReceived() {
        view.blocksDidChange()
        let columns = terminalView.getTerminal().cols
        if columns != lastColumns {
            lastColumns = columns
            remapAfterReflow()
        }
        scheduleCwdPoll()
    }

    /// Plain shells don't report their cwd, so read it from the kernel shortly after output.
    private func scheduleCwdPoll() {
        guard !sawOSC7, !cwdPollScheduled else { return }
        cwdPollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.cwdPollScheduled = false
            guard self.state == .running,
                  let pid = self.terminalView.process?.shellPid,
                  let path = ProcessInfoReader.currentDirectory(of: pid),
                  path != self.currentDirectory
            else { return }
            self.currentDirectory = path
            self.refreshGitBranch()
            self.view.contextDidChange()
            self.onChange?()
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        if newCols != lastColumns {
            lastColumns = newCols
            remapAfterReflow()
        }
        view.blocksDidChange()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let path = TabTitle.pathFromOSC7(directory) else { return }
        sawOSC7 = true
        guard path != currentDirectory else { return }
        currentDirectory = path
        refreshGitBranch()
        view.contextDidChange()
        onChange?()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // We asked for this (tab/window closed); nothing to show.
        if case .exited = state { return }
        integrationTimeout?.cancel()
        liveTimer?.invalidate()
        liveTimer = nil

        let exit = exitCode.map(ProcessExit.init(waitStatus:))
        state = .exited(exit)
        if Date().timeIntervalSince(startedAt) >= Self.earlyExitWindow {
            onRequestClose?()
            return
        }

        let reason: String
        switch exit {
        case .exited(let code)?: reason = "exited with code \(code)"
        case .signaled(let signal)?: reason = "was killed by signal \(signal)"
        case nil: reason = "stopped (I/O error)"
        }
        integration = .unavailable
        mode = .plainTerminal
        view.modeDidChange()
        terminalView.feed(text: "\r\n\u{1b}[2m[Process \(reason). Press Return to restart or ⌘W to close.]\u{1b}[0m\r\n")
    }

    private func restartAfterExit() {
        terminalView.getTerminal().resetToInitialState()
        tracker.removeAll()
        anchorLines.removeAll()
        mode = .editor
        start()
    }
}

/// Menu item that carries a block and a handler.
final class BlockMenuItem: NSMenuItem {
    private let block: Block
    private let handler: (Block) -> Void

    init(title: String, block: Block, handler: @escaping (Block) -> Void) {
        self.block = block
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler(block)
    }
}
