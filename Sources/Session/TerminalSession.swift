import AppKit
import RuneKit
import SwiftTerm

/// SwiftTerm view with the hooks Rune needs.
final class RuneTerminalView: LocalProcessTerminalView {
    var onDataReceived: (() -> Void)?
    /// Viewport moved; the argument is 0 (top of scrollback) … 1 (following the output).
    var onScrolled: ((Double) -> Void)?
    var onBufferSwitched: (() -> Void)?
    /// When set, keyboard input is offered here instead of the PTY. Return true to consume it.
    var inputInterceptor: ((ArraySlice<UInt8>) -> Bool)?
    /// A ⌘-clicked link; return true if handled (otherwise SwiftTerm opens it).
    var onOpenLink: ((String) -> Bool)?
    /// Supplies a context menu for a click location (block actions).
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?

    private var bypassInterceptor = false

    /// Sees output before it's drawn; returns the part to draw (Rune hides the remote setup
    /// script this way).
    var outputFilter: ((ArraySlice<UInt8>) -> ArraySlice<UInt8>)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let shown = outputFilter?(slice) ?? slice
        if !shown.isEmpty { super.dataReceived(slice: shown) }
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

    /// ⌘C, given the selected text (nil when nothing is selected). Return true if handled.
    var copyHandler: ((String?) -> Bool)?
    /// Whether ⌘C can do something with no text selected (a block is selected).
    var canCopyWithoutSelection: (() -> Bool)?

    /// A click that didn't select text or open a link: point in view coordinates, and whether
    /// ⇧ was held.
    var onPlainClick: ((NSPoint, Bool) -> Void)?
    private var pressLocation: NSPoint?
    private var pressHadSelection = false

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
        pressHadSelection = selection.active
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { pressLocation = nil }
        guard event.clickCount == 1, let start = pressLocation, !event.modifierFlags.contains(.command),
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4,
              !selection.active, !pressHadSelection || event.modifierFlags.contains(.shift)
        else { return }
        onPlainClick?(convert(event.locationInWindow, from: nil), event.modifierFlags.contains(.shift))
    }

    override func copy(_ sender: Any) {
        if copyHandler?(selection.active ? getSelection() : nil) == true { return }
        super.copy(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), !selection.active, canCopyWithoutSelection?() == true { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if onOpenLink?(link) == true { return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScrolled?(position)
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
    private(set) var currentDirectory: String {
        didSet { if currentDirectory != oldValue { RecentDirectories.shared.record(currentDirectory) } }
    }
    private(set) var gitBranch: String?
    private(set) var integration: IntegrationState = .pending
    private(set) var mode: InputMode = .editor
    /// Block highlighted by Cmd-Up/Down or a click: the end of the selection that moves.
    private(set) var selectedBlockID: Int?
    /// Every selected block (⇧-click or ⇧⌘↑ selects a range).
    private(set) var selectedBlockIDs: Set<Int> = []
    private var selectionAnchorID: Int?
    /// Open two runs' outputs as a diff.
    var onCompare: ((OutputCompareModel.Run, OutputCompareModel.Run) -> Void)?

    /// Title, cwd or mode changed.
    var onChange: (() -> Void)?
    /// The shell exited and the tab should close.
    var onRequestClose: (() -> Void)?
    /// Open a new tab with this text pre-filled in the input editor (not run).
    var onRequestNewTab: ((String?) -> Void)?
    /// Show a file in a Rune preview tab, optionally at a line.
    var onOpenFile: ((String, Int?) -> Void)?

    private var snapshot: ConfigSnapshot
    private var startedAt = Date()
    /// Where a folder change for an idle shell is written before signalling it (see rune.zsh).
    private lazy var cdRequestFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("rune-cd-\(id.uuidString)")
    /// The shell has drawn its first prompt (its startup files have finished).
    private(set) var hasPrompted = false
    /// A folder to move to once the shell is ready.
    private var pendingDirectory: String?
    /// A command to run once the shell is at its first prompt (a pane from a launch layout).
    private var pendingStartCommand: String?

    // MARK: Remote shells

    enum RemoteState: Equatable {
        case none
        /// A login command runs; waiting for a shell prompt on the other side.
        case watching(host: String)
        /// The user is being asked whether to use Rune's input there.
        case offered(host: String)
        /// The setup script was typed; its output is hidden until it reports back.
        case settingUp(host: String)
        /// The remote shell reports prompts and commands; the editor owns input.
        case active(host: String)
    }
    private(set) var remote: RemoteState = .none
    var isRemote: Bool { if case .active = remote { return true } else { return false } }
    /// The remote shell's working directory (a path on the other machine).
    private(set) var remoteDirectory: String?
    private var promptCheck: DispatchWorkItem?
    /// Output held back while the setup script runs (shown again if it fails).
    private var heldOutput: [UInt8]?
    private var setupTimeout: DispatchWorkItem?
    private static let alwaysHostsKey = "RuneRemoteInputHosts"
    /// Commands submitted with a leading space, not to be recorded in Recall.
    private var privateCommands: Set<String> = []
    private var sawOSC7 = false
    private var cwdPollScheduled = false
    private var integrationTimeout: DispatchWorkItem?
    private var historyNavigator = HistoryNavigator()
    /// Buffer lines backing the rows the tracker knows about, so rows can be re-found after
    /// the terminal reflows on resize.
    private var anchorLines: [Int: BufferLine] = [:]
    private var lastColumns = 0
    private var liveTimer: Timer?
    /// Held while a command runs so App Nap doesn't throttle output processing when Rune
    /// is in the background (e.g. a long build while you work elsewhere).
    private var commandActivity: NSObjectProtocol?
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
        terminalView.onScrolled = { [weak self] position in self?.viewportDidScroll(to: position) }
        terminalView.onBufferSwitched = { [weak self] in self?.updateMode() }
        terminalView.inputInterceptor = { [weak self] data in self?.intercept(data) ?? false }
        terminalView.contextMenuProvider = { [weak self] point in self?.contextMenu(atTerminalPoint: point) }
        terminalView.onOpenLink = { [weak self] link in self?.openLink(link) ?? false }
        terminalView.copyHandler = { [weak self] selected in self?.copySelection(selected) ?? false }
        terminalView.onPlainClick = { [weak self] point, extend in self?.clickedOutput(atTerminalPoint: point, extend: extend) }
        terminalView.canCopyWithoutSelection = { [weak self] in self?.canCopySelectedBlock ?? false }
        terminalView.outputFilter = { [weak self] slice in self?.filterOutput(slice) ?? slice }
        installOSCHandlers()
        apply(snapshot)
        HistoryStore.shared.loadIfNeeded()
        // Rune draws its own overlay scroll indicator (BlockOverlayView).
        terminalView.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
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
        if tv.isUsingMetalRenderer != config.gpuRendering {
            // Without a usable Metal device this throws and the terminal keeps CPU drawing.
            try? tv.setUseMetal(config.gpuRendering)
        }
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
            env["RUNE_CD_FILE"] = cdRequestFile.path
            integration = .pending
            // Keep the caret hidden while zsh loads; the integration shows it when it's
            // actually needed (at the real prompt, or when a command runs). Without this the
            // caret blinks at the top-left for the second or two a heavy .zshrc takes.
            terminalView.feed(text: "\u{1b}[?25l")
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.integration == .pending else { return }
                self.integration = .unavailable
                self.terminalView.feed(text: "\u{1b}[?25h")
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
        // Start at the bottom: output grows upward from the input, like a chat.
        padToBottom()
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

    /// Moves a shell that's sitting at its prompt to `directory` without running a visible
    /// command: used when a pre-started shell is handed to a tab for another folder.
    /// The command running in this pane, for a saved layout to start again (not private
    /// commands, and not what runs inside a remote shell).
    var layoutCommand: String? {
        guard !isRemote, tracker.isCommandRunning, let block = tracker.blocks.last, block.state == .running,
              !block.command.isEmpty, !privateCommands.contains(block.command) else { return nil }
        return block.command
    }

    /// Runs `command` as soon as the shell is ready, as if typed in the editor and entered.
    func runWhenReady(_ command: String) {
        guard hasPrompted, pendingDirectory == nil, mode == .editor else {
            pendingStartCommand = command
            return
        }
        runStartCommand(command)
    }

    private func runStartCommand(_ command: String) {
        // After the quiet `cd` a pooled shell may still be doing (moveIdleShell).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.submit(command) }
    }

    func moveIdleShell(to directory: String) {
        guard directory != currentDirectory, FileManager.default.fileExists(atPath: directory) else { return }
        guard hasPrompted, integration == .active, mode == .editor || mode == .shellPrompt,
              let pid = terminalView.process?.shellPid
        else {
            pendingDirectory = directory
            return
        }
        do {
            try directory.write(to: cdRequestFile, atomically: true, encoding: .utf8)
            kill(pid, SIGUSR1)
        } catch {
            // Can't hand it over quietly; the tab stays where the shell started.
        }
    }

    /// Moves the cursor to the last row by adding blank lines above it.
    private func padToBottom() {
        let terminal = terminalView.getTerminal()
        let missing = terminal.rows - 1 - terminal.getCursorLocation().y
        if missing > 0 {
            terminalView.feed(text: String(repeating: "\r\n", count: missing))
        }
    }

    /// Rune's own prompt is invisible, so after `clear` / ⌘K the empty prompt can be moved to
    /// the bottom row without the shell noticing. Tells the tracker where the prompt now is.
    private var promptIsInvisible: Bool {
        mode == .editor && !typeInShell && !config.honorPrompt
    }

    private func reanchorPromptAtBottom() {
        guard promptIsInvisible else { return }
        let before = terminalView.getTerminal().getCursorLocation().y
        guard before < terminalView.getTerminal().rows - 1 else { return }
        padToBottom()
        let cursor = geometry.cursorPosition
        tracker.handle(.promptStart, at: MarkPosition(row: cursor.row - 1, column: 0))
        tracker.handle(.commandStart, at: MarkPosition(row: cursor.row, column: 0))
        let terminal = terminalView.getTerminal()
        for row in [cursor.row - 1, cursor.row] {
            if let line = terminal.getScrollInvariantLine(row: row) { anchorLines[row] = line }
        }
        view.blocksDidChange()
    }

    private static func zshIntegrationDirectory() -> String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("ShellIntegration/zsh", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent(".zshenv").path)
        else { return nil }
        return dir.path
    }

    /// Name of a program running in this tab (vim, npm, ssh…), or nil when the shell is idle.
    var runningProgram: String? {
        guard state == .running, let pid = terminalView.process?.shellPid else { return nil }
        let commandRunning = tracker.isCommandRunning
        let children = ProcessInfoReader.childProcessNames(of: pid).filter { name in
            // Background helpers some prompt themes keep alive while the shell is idle.
            if name.hasPrefix("gitstatusd") { return false }
            if !commandRunning, name == "zsh" || name == "-zsh" || name == "sh" { return false }
            return true
        }
        if let first = children.first { return first }
        if tracker.isCommandRunning { return tracker.blocks.last?.command.components(separatedBy: " ").first }
        return nil
    }

    func terminate() {
        if let activity = commandActivity {
            ProcessInfo.processInfo.endActivity(activity)
            commandActivity = nil
        }
        integrationTimeout?.cancel()
        try? FileManager.default.removeItem(at: cdRequestFile)
        view.conversation.dismiss()
        liveTimer?.invalidate()
        guard state == .running else { return }
        state = .exited(nil)
        terminalView.onDataReceived = nil
        terminalView.terminate()
    }

    // MARK: - Commands from the input editor

    /// Runs `command` in the shell (Enter in the editor).
    func submit(_ command: String) {
        var trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state == .running else { return }
        // A leading space means "don't remember this" (zsh's HIST_IGNORE_SPACE): keep it out
        // of Rune's history and Recall, and pass the space on so zsh skips it too.
        // A remote shell set up by Rune doesn't report the command text; the block gets it here.
        if isRemote { _ = tracker.handle(.commandText(trimmed), at: MarkPosition(row: geometry.cursorPosition.row, column: 0)) }
        if command.hasPrefix(" ") {
            privateCommands.insert(trimmed)
            trimmed = " " + trimmed
        } else {
            HistoryStore.shared.append(trimmed)
        }
        historyNavigator.reset()
        selectBlock(nil)
        view.dismissWelcomeForSession()
        // Make room for the output; the conversation stays available for follow-ups.
        view.conversation.collapse()

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
        // Files on the other machine aren't visible from here.
        guard !isRemote else { return nil }
        return PathCompletion.complete(text: text, cursor: cursor, cwd: currentDirectory, home: NSHomeDirectory())
    }

    /// Ctrl-D on an empty editor.
    func sendEOF() {
        terminalView.sendToShell([4])
    }

    /// Cmd-K: clears output and blocks, then lets the shell redraw its prompt.
    func clearScreen() {
        tracker.removeAll()
        anchorLines.removeAll()
        selectBlock(nil)
        terminalView.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        if promptIsInvisible, integration == .active {
            reanchorPromptAtBottom()
        } else if mode == .editor || mode == .shellPrompt {
            terminalView.sendToShell([12]) // Ctrl-L: the shell redraws its prompt
        }
        view.blocksDidChange()
    }

    func interrupt() {
        terminalView.sendToShell([3])
    }

    // MARK: - AI

    /// Sends `request` to the selected local model. The selected block (⌘↑) or, if allowed in
    /// settings, the most recent block goes along as context.
    /// ⌘-click on a link in the output. File paths resolve against the folders commands ran
    /// in (newest first) and open at their line in editors that support it.
    private func openLink(_ link: String) -> Bool {
        var folders = [currentDirectory]
        for block in tracker.blocks.reversed() where !block.cwd.isEmpty && !folders.contains(block.cwd) { folders.append(block.cwd) }
        guard let target = LinkTarget.resolve(link, folders: folders) else { return false }
        switch target {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .file(let path, let line, let column):
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let fileURL = URL(fileURLWithPath: path)
            if isDirectory.boolValue {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } else if config.openFilesIn == "rune", let onOpenFile {
                onOpenFile(path, line)
            } else if let line, let app = NSWorkspace.shared.urlForApplication(toOpen: fileURL),
                      let bundle = Bundle(url: app)?.bundleIdentifier,
                      let editorURL = EditorLink.url(bundleIdentifier: bundle, path: path, line: line, column: column) {
                NSWorkspace.shared.open(editorURL)
            } else {
                NSWorkspace.shared.open(fileURL)
            }
        }
        return true
    }



    func askAI(_ request: String, about explicitBlock: Block? = nil) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let service = AIService.shared
        guard service.isEnabled else { NSSound.beep(); return }
        let conversation = view.conversation
        view.dismissWelcomeForSession()

        guard service.isReady, let model = service.activeModel else {
            conversation.showSetup(prompt: trimmed)
            service.refresh { [weak self] in
                // If Ollama turned out to be ready, send right away.
                if AIService.shared.isReady, self?.view.conversation.state == .setup {
                    self?.askAI(trimmed, about: explicitBlock)
                }
            }
            return
        }

        // Follow-ups continue the open conversation; its context was already sent, so only
        // attach a block the user explicitly picked.
        let followUp = conversation.canFollowUp && explicitBlock == nil
        var block = explicitBlock
        if block == nil, let id = selectedBlockID { block = tracker.block(id: id) }
        if block == nil, !followUp, config.aiIncludeBlockContext { block = tracker.blocks.last { $0.state == .finished } }

        let listing = FileListing.entries(at: currentDirectory, showHidden: false)
            .prefix(AIPrompt.maxListing + 40)
            .map { $0.isDirectory ? $0.name + "/" : $0.name }
        // Credentials never leave the terminal, even to a local model (logs, history, remote hosts).
        let context = AIContext(
            request: SecretRedactor.redact(trimmed),
            cwd: currentDirectory,
            osVersion: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            shell: (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?.lastPathComponent ?? "zsh",
            gitBranch: gitBranch,
            directoryListing: Array(listing),
            blockCommand: block.map { SecretRedactor.redact(commandText(of: $0)) },
            blockOutput: block.map { SecretRedactor.redact(outputText(of: $0)) },
            blockExitCode: block?.exitCode
        )
        let label = block.map { b -> String in
            let name = commandText(of: b).components(separatedBy: "\n").first ?? ""
            let short = name.count > 28 ? String(name.prefix(27)) + "…" : name
            return b.isFailed ? "\(short) (exit \(b.exitCode ?? 1))" : short
        }
        conversation.ask(context, model: model, client: service.client,
                         disableThinking: service.activeModelInfo?.supportsThinking ?? false,
                         contextLabel: label, followUp: followUp)
    }

    /// "Explain this error" for a failed block.
    func explain(_ block: Block) {
        askAI(AIPrompt.explainErrorRequest(command: commandText(of: block)), about: block)
    }

    // MARK: - Blocks

    /// ⌘↑/⌘↓ move the selection a block at a time; with ⇧ they extend it.
    func selectAdjacentBlock(previous: Bool, extend: Bool = false) {
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
            selectBlock(nil)
            terminalView.scrollTo(row: Int.max)
            view.focusPreferredResponder()
            return
        }
        let block = blocks[index]
        selectBlock(block.id, extend: extend)
        scrollToTop(row: block.headerRow)
    }

    /// Selects one block, or (with `extend`) every block from the selection's anchor to it.
    func selectBlock(_ id: Int?, extend: Bool = false) {
        defer { view.blocksDidChange() }
        guard let id else {
            selectedBlockID = nil
            selectedBlockIDs = []
            selectionAnchorID = nil
            return
        }
        let blocks = tracker.blocks
        if extend, let anchor = selectionAnchorID ?? selectedBlockID,
           let from = blocks.firstIndex(where: { $0.id == anchor }), let to = blocks.firstIndex(where: { $0.id == id }) {
            selectedBlockIDs = Set(blocks[min(from, to)...max(from, to)].map(\.id))
            selectionAnchorID = anchor
        } else {
            selectedBlockIDs = [id]
            selectionAnchorID = id
        }
        selectedBlockID = id
    }

    /// The selected blocks, oldest first.
    var selectedBlocks: [Block] { tracker.blocks.filter { selectedBlockIDs.contains($0.id) } }

    /// A click (not a drag) on the output: selects the block under it, ⇧ extends the
    /// selection, and clicking the only selected block again (or empty space) deselects.
    func clickedOutput(atTerminalPoint point: NSPoint, extend: Bool) {
        guard mode == .editor || mode == .runningCommand else { return }
        let row = geometry.row(atY: point.y)
        guard let index = tracker.blockIndex(containing: row, currentRow: geometry.cursorPosition.row) else {
            selectBlock(nil)
            return
        }
        let id = tracker.blocks[index].id
        if !extend, selectedBlockIDs == [id] {
            selectBlock(nil)
        } else {
            selectBlock(id, extend: extend)
        }
    }

    // MARK: - Comparing runs

    /// The last earlier run of the same command, if any.
    func previousRun(of block: Block) -> Block? {
        let command = commandText(of: block).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = tracker.blocks.firstIndex(where: { $0.id == block.id }) else { return nil }
        return tracker.blocks[..<index].last {
            $0.state == .finished && commandText(of: $0).trimmingCharacters(in: .whitespacesAndNewlines) == command
        }
    }

    /// Opens a diff of two blocks' outputs, older one first.
    func compare(_ first: Block, _ second: Block) {
        let (old, new) = first.startedAt <= second.startedAt ? (first, second) : (second, first)
        func run(_ block: Block) -> OutputCompareModel.Run {
            OutputCompareModel.Run(command: commandText(of: block), output: outputText(of: block),
                                   startedAt: block.startedAt, exitCode: block.exitCode, failed: block.isFailed)
        }
        onCompare?(run(old), run(new))
    }

    /// The two selected blocks; otherwise the latest command against its previous run, or
    /// the last two commands.
    func compareLatestRuns() {
        let selected = selectedBlocks
        if selected.count == 2 { return compare(selected[0], selected[1]) }
        let finished = tracker.blocks.filter { $0.state == .finished }
        if let latest = finished.last, let previous = previousRun(of: latest) { return compare(previous, latest) }
        if finished.count >= 2 { return compare(finished[finished.count - 2], finished[finished.count - 1]) }
        NSSound.beep()
    }

    /// Scrolls so a (scroll-invariant) row is the first one on screen, below any rows the
    /// input area covers.
    func scrollToTop(row: Int) {
        terminalView.scrollTo(row: max(0, row - geometry.linesTrimmed - view.terminalContainer.coveredTopRows))
    }

    func clearBlockSelection() {
        guard selectedBlockID != nil || !selectedBlockIDs.isEmpty else { return }
        selectBlock(nil)
    }

    func commandText(of block: Block) -> String {
        if !block.command.isEmpty { return block.command }
        let last = max(block.commandRow, block.outputStartRow - 1)
        return geometry.text(rows: block.commandRow...last)
    }

    func outputText(of block: Block, maxRows: Int? = nil) -> String {
        let current = geometry.cursorPosition.row
        guard var rows = block.outputRows(currentRow: current) else { return "" }
        if let maxRows, rows.count > maxRows {
            rows = (rows.upperBound - maxRows + 1)...rows.upperBound
        }
        return geometry.text(rows: rows)
    }

    enum CopyKind {
        case command, output, commandAndOutput, markdown, image
        /// The output with masked secrets in it, as the program printed them.
        case outputWithSecrets
    }

    /// Copies part of a block and says so next to it. Copies what the screen shows: secrets
    /// masked in the output stay masked unless they were clicked to reveal.
    func copy(_ kind: CopyKind, of block: Block) {
        var hidden = 0
        let message: String
        switch kind {
        case .command:
            copyToPasteboard(shown(commandText(of: block), hidden: &hidden))
            message = "Copied command"
        case .output, .outputWithSecrets:
            let output = outputText(of: block)
            guard !output.isEmpty else {
                view.overlay.showCopied("No output to copy", for: block)
                return
            }
            copyToPasteboard(kind == .output ? shown(output, hidden: &hidden) : output)
            let lines = output.components(separatedBy: "\n").count
            message = "Copied \(lines == 1 ? "1 line" : "\(lines.formatted()) lines") of output"
        case .commandAndOutput:
            copyToPasteboard(shown(transcript(of: block), hidden: &hidden))
            message = "Copied command and output"
        case .markdown:
            // Always without secrets: Markdown is for pasting somewhere else.
            let markdown = markdownText(of: block)
            hidden = SecretRedactor.matches(in: markdown).count
            copyToPasteboard(SecretRedactor.redact(markdown))
            message = "Copied as Markdown"
        case .image:
            guard let png = blockImage(of: block) else {
                NSSound.beep()
                return
            }
            hidden = png.hidden
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png.data, forType: .png)
            message = "Copied as image"
        }
        view.overlay.showCopied(message + Self.hiddenNote(hidden), for: block, action: kind)
    }

    /// Whether the block's output has secrets that copying would mask.
    func hasMaskedSecrets(_ block: Block) -> Bool {
        guard config.hideSecrets else { return false }
        let revealed = view.overlay.revealedSecrets
        let output = outputText(of: block)
        return SecretRedactor.matches(in: output).contains { !revealed.contains((output as NSString).substring(with: $0.range)) }
    }

    /// ⌘C with no text selected copies the selected blocks. Returns false if there are none.
    @discardableResult
    func copySelectedBlock() -> Bool {
        let blocks = selectedBlocks
        guard !blocks.isEmpty else { return false }
        if blocks.count == 1 {
            copy(.commandAndOutput, of: blocks[0])
        } else {
            copy(.commandAndOutput, of: blocks)
        }
        return true
    }

    var canCopySelectedBlock: Bool { !selectedBlocks.isEmpty }

    /// Several blocks at once (a ⇧-selected range): one after the other.
    func copy(_ kind: CopyKind, of blocks: [Block]) {
        guard let last = blocks.last else { return }
        guard blocks.count > 1 else { return copy(kind, of: last) }
        var hidden = 0
        let noun = "\(blocks.count) blocks"
        switch kind {
        case .image:
            guard let png = blockImage(of: blocks) else { return NSSound.beep() }
            hidden = png.hidden
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png.data, forType: .png)
            view.overlay.showCopied("Copied \(noun) as image" + Self.hiddenNote(hidden), for: last)
        case .markdown:
            let markdown = blocks.map(markdownText(of:)).joined(separator: "\n\n")
            hidden = SecretRedactor.matches(in: markdown).count
            copyToPasteboard(SecretRedactor.redact(markdown))
            view.overlay.showCopied("Copied \(noun) as Markdown" + Self.hiddenNote(hidden), for: last)
        default:
            let text = blocks.map { transcript(of: $0) }.joined(separator: "\n\n")
            copyToPasteboard(shown(text, hidden: &hidden))
            view.overlay.showCopied("Copied \(noun)" + Self.hiddenNote(hidden), for: last)
        }
    }

    private static func hiddenNote(_ hidden: Int) -> String {
        hidden == 0 ? "" : "  ·  \(hidden) secret\(hidden == 1 ? "" : "s") hidden"
    }

    /// ⇧⌘C: the output of the selected block, or of the last command that printed something.
    func copyLatestOutput() {
        copyLatestBlock(as: .output)
    }

    /// The selected block, or the last finished command with output.
    func copyLatestBlock(as kind: CopyKind) {
        let current = geometry.cursorPosition.row
        let block = selectedBlockID.flatMap(tracker.block(id:))
            ?? tracker.blocks.last { $0.state == .finished && $0.outputRows(currentRow: current) != nil }
            ?? tracker.blocks.last
        guard let block else {
            NSSound.beep()
            return
        }
        copy(kind, of: block)
    }

    /// Text selected with the mouse: trailing padding trimmed from each line, masked secrets
    /// kept masked.
    private func copySelection(_ selected: String?) -> Bool {
        guard let selected, !selected.isEmpty else { return copySelectedBlock() }
        let trimmed = selected.components(separatedBy: "\n").map { line in
            String(line.reversed().drop { $0 == " " }.reversed())
        }.joined(separator: "\n")
        var hidden = 0
        copyToPasteboard(shown(trimmed, hidden: &hidden))
        if hidden > 0 {
            view.overlay.showCopied("Copied  ·  \(hidden) secret\(hidden == 1 ? "" : "s") hidden (click one to reveal it)", for: nil)
        }
        return true
    }

    /// `text` as the screen shows it: with secret hiding on, secrets the user hasn't revealed
    /// are replaced by a label.
    private func shown(_ text: String, hidden: inout Int) -> String {
        guard config.hideSecrets else { return text }
        let revealed = view.overlay.revealedSecrets
        var result = text as NSString
        for match in SecretRedactor.matches(in: text).reversed() {
            guard !revealed.contains((text as NSString).substring(with: match.range)) else { continue }
            result = result.replacingCharacters(in: match.range, with: "[redacted \(match.kind)]") as NSString
            hidden += 1
        }
        return result as String
    }

    /// `$ command` followed by its output, as it looked in the terminal.
    private func transcript(of block: Block) -> String {
        let output = outputText(of: block)
        let command = "$ " + commandText(of: block).replacingOccurrences(of: "\n", with: "\n> ")
        return output.isEmpty ? command : command + "\n" + output
    }

    /// The command and its output as a Markdown code block, for chats, issues and docs.
    private func markdownText(of block: Block) -> String {
        var markdown = "```console\n" + transcript(of: block) + "\n```"
        if block.isFailed, let code = block.exitCode { markdown += "\n_exit \(code)_" }
        return markdown
    }

    private func blockImage(of block: Block) -> (data: Data, hidden: Int)? {
        blockImage(of: [block])
    }

    private func blockImage(of blocks: [Block]) -> (data: Data, hidden: Int)? {
        let terminal = terminalView.getTerminal()
        let current = geometry.cursorPosition.row
        // A long selection keeps the newest output: about as many lines as one block gets.
        var budget = BlockImage.maxOutputLines
        var sections: [BlockImage.Section] = []
        for block in blocks.reversed() {
            var rows: [BufferLine] = []
            var omitted = 0
            if let range = block.outputRows(currentRow: current) {
                let keep = max(0, min(range.count, budget))
                budget -= keep
                omitted = range.count - keep
                if keep > 0 {
                    rows = ((range.upperBound - keep + 1)...range.upperBound).compactMap { terminal.getScrollInvariantLine(row: $0) }
                }
            }
            var status = [TabTitle.abbreviate(path: block.cwd, home: NSHomeDirectory())]
            if block.isFailed, let code = block.exitCode { status.append("exit \(code)") }
            if block.state == .finished { status.append(BlockOverlayView.format(duration: block.duration())) }
            sections.insert(BlockImage.Section(command: commandText(of: block), rows: rows, omittedLines: omitted,
                                               status: status.joined(separator: "  ·  "), failed: block.isFailed), at: 0)
        }
        return BlockImage.png(sections, style: BlockImage.Style(
            terminalColumns: terminal.cols,
            theme: snapshot.theme,
            palette: palette,
            font: terminalView.font,
            maskSecrets: config.hideSecrets,
            revealed: view.overlay.revealedSecrets
        ))
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
        let menu = blockMenu(for: tracker.blocks[index])
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        return menu
    }

    /// Everything you can do with a block: copying it in various forms, filtering, re-running.
    func blockMenu(for block: Block) -> NSMenu {
        let selected = selectedBlocks
        if selected.count > 1, selectedBlockIDs.contains(block.id) { return selectionMenu(for: selected) }
        let menu = NSMenu()
        menu.addItem(BlockMenuItem(title: "Copy Command", block: block) { [weak self] in self?.copy(.command, of: $0) })
        menu.addItem(BlockMenuItem(title: "Copy Output", block: block) { [weak self] in self?.copy(.output, of: $0) })
        menu.addItem(BlockMenuItem(title: "Copy Command and Output", block: block) { [weak self] in self?.copy(.commandAndOutput, of: $0) })
        if hasMaskedSecrets(block) {
            menu.addItem(BlockMenuItem(title: "Copy Output Including Secrets", block: block) { [weak self] in self?.copy(.outputWithSecrets, of: $0) })
        }
        menu.addItem(BlockMenuItem(title: "Copy as Markdown", block: block) { [weak self] in self?.copy(.markdown, of: $0) })
        menu.addItem(BlockMenuItem(title: "Copy as Image", block: block) { [weak self] in self?.copy(.image, of: $0) })
        menu.addItem(.separator())
        if let previous = previousRun(of: block) {
            menu.addItem(BlockMenuItem(title: "Compare with Previous Run", block: block) { [weak self] in self?.compare(previous, $0) })
        }
        menu.addItem(BlockMenuItem(title: "Filter Output…", block: block) { [weak self] b in
            guard let self else { return }
            self.view.showFilter(command: self.commandText(of: b), output: self.outputText(of: b, maxRows: BlockFilterModel.maxLines))
        })
        let rerunItem = BlockMenuItem(title: "Re-run Command", block: block) { [weak self] in self?.rerun($0) }
        rerunItem.isEnabled = mode == .editor
        menu.addItem(rerunItem)
        if block.isFailed, AIService.shared.isEnabled {
            menu.addItem(BlockMenuItem(title: "Explain This Error", block: block) { [weak self] in self?.explain($0) })
        }
        if AIService.shared.isEnabled {
        menu.addItem(BlockMenuItem(title: "Ask AI About This Block…", block: block) { [weak self] b in
            guard let self else { return }
            self.selectBlock(b.id)
            self.view.inputArea.focusEditor()
        })
        }
        return menu
    }

    /// Actions on a ⇧-selected range of blocks.
    private func selectionMenu(for blocks: [Block]) -> NSMenu {
        let menu = NSMenu()
        let count = blocks.count
        menu.addItem(ClosureMenuItem(title: "Copy \(count) Blocks") { [weak self] in self?.copy(.commandAndOutput, of: blocks) })
        menu.addItem(ClosureMenuItem(title: "Copy \(count) Blocks as Markdown") { [weak self] in self?.copy(.markdown, of: blocks) })
        menu.addItem(ClosureMenuItem(title: "Copy \(count) Blocks as Image") { [weak self] in self?.copy(.image, of: blocks) })
        if count == 2 {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Compare Outputs") { [weak self] in self?.compare(blocks[0], blocks[1]) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Clear Selection") { [weak self] in self?.selectBlock(nil) })
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
        if case .commandStart = mark, !hasPrompted {
            hasPrompted = true
            if let directory = pendingDirectory {
                pendingDirectory = nil
                DispatchQueue.main.async { [weak self] in self?.moveIdleShell(to: directory) }
            }
        }
        if case .commandStart = mark, let command = pendingStartCommand {
            pendingStartCommand = nil
            runStartCommand(command)
        }
        let wasRunning = tracker.isCommandRunning
        let changed = tracker.handle(mark, at: position)
        if case .outputStart = mark, config.remoteInput != "off", let block = tracker.blocks.last, block.state == .running,
           RemoteShell.isLoginCommand(block.command) {
            remote = .watching(host: RemoteShell.hostLabel(for: block.command))
        }
        if case .commandFinished = mark, wasRunning, let block = tracker.blocks.last, block.state == .finished {
            notifyIfUnattended(block)
            recordInRecall(block)
            suggestCorrection(for: block)
        }

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
        case .remoteHost(let host):
            remote = .active(host: host)
            view.hideRemoteOffer()
            view.contextDidChange()
        case .remoteDirectory(let path):
            remoteDirectory = path
            if case .active(let host) = remote {
                _ = tracker.handle(.currentDirectory(host + ":" + path), at: position)
            }
            view.contextDidChange()
        case .remoteReady:
            break
        case .currentDirectory(let path):
            // Back in the local shell (ssh ended).
            if remote != .none {
                remote = .none
                view.hideRemoteOffer()
            }
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

    /// Saves the command and (the end of) its output to Rune Recall. Commands typed with a
    /// leading space are skipped, like zsh's HIST_IGNORE_SPACE.
    private func recordInRecall(_ block: Block) {
        let command = commandText(of: block).trimmingCharacters(in: .whitespacesAndNewlines)
        if privateCommands.remove(command) != nil { return }
        guard config.recallEnabled, !block.command.hasPrefix(" "), !command.isEmpty else { return }
        RecallService.shared.record(command: command, output: outputText(of: block, maxRows: RecallService.maxOutputLines),
                                    directory: block.cwd.isEmpty ? currentDirectory : block.cwd,
                                    exitCode: block.exitCode, duration: block.duration())
    }

    /// A command failed because of a typo: offer the fixed command (Tab puts it in the input).
    private func suggestCorrection(for block: Block) {
        guard block.isFailed || block.exitCode == 127 else { view.inputArea.showCorrection(nil); return }
        let directories = isRemote ? [] : FileListing.entries(at: currentDirectory, showHidden: true).filter(\.isDirectory).map(\.name)
        let fix = CommandCorrection.suggest(command: commandText(of: block), exitCode: block.exitCode,
                                            output: outputText(of: block, maxRows: 40),
                                            knownCommands: CommandCatalog.shared.allNames, directories: directories)
        view.inputArea.showCorrection(fix)
    }

    /// A long command finished while this pane wasn't in view: post a notification.
    private func notifyIfUnattended(_ block: Block) {
        let settings = config
        let duration = block.duration()
        guard settings.notifyWhenDone, duration >= settings.notifyAfterSeconds else { return }
        let window = view.window
        let watching = NSApp.isActive && window?.isKeyWindow == true && window?.isMiniaturized == false
            && !view.isHiddenOrHasHiddenAncestor
        guard !watching else { return }
        CommandNotifier.shared.commandFinished(command: block.command, exitCode: block.exitCode, duration: duration, sessionID: id)
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
        if running, commandActivity == nil {
            commandActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Running a command in Rune")
        } else if !running, let activity = commandActivity {
            ProcessInfo.processInfo.endActivity(activity)
            commandActivity = nil
        }
        if running, liveTimer == nil {
            // Live duration counter for the running block.
            liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.view.blocksDidChange()
            }
        } else if !running {
            liveTimer?.invalidate()
            liveTimer = nil
        }
        defer { updateBottomTrim() }
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

    /// Keeps output anchored right above the input editor: blank rows at the bottom of the
    /// screen are pushed out of view instead of being filled with padding. Blank rows appear
    /// below the cursor after `clear` or when the terminal grows (the window, or the welcome
    /// panel closing). At Rune's invisible prompt the spacer and cursor rows are hidden too;
    /// otherwise the cursor row always stays visible. Full-screen apps are left alone.
    func updateBottomTrim() {
        let terminal = terminalView.getTerminal()
        var hidden = 0
        if integration == .active, !terminal.isCurrentBufferAlternate, case .running = state {
            let lowestHideable = promptIsInvisible ? 1 : terminal.getCursorLocation().y + 1
            let screenTop = geometry.linesTrimmed + geometry.screenTop
            var row = terminal.rows - 1
            while row >= max(1, lowestHideable),
                  let line = terminal.getScrollInvariantLine(row: screenTop + row),
                  line.translateToString(trimRight: true).isEmpty {
                hidden += 1
                row -= 1
            }
        }
        // SwiftTerm's find bar hangs from the terminal's top edge: keep that edge near the top
        // of the pane while it's open.
        let findBar = isFindBarVisible
        if findBar { hidden = min(hidden, 2) }
        view.terminalContainer.keepsTopVisible = findBar
        view.terminalContainer.hiddenBottomRows = hidden
    }

    private var isFindBarVisible: Bool {
        terminalView.subviews.contains { !$0.isHidden && String(describing: type(of: $0)) == "TerminalFindBarView" }
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

    /// Called for every line that scrolls by. Chrome is redrawn with the text (coalesced per
    /// frame); the scroll indicator only appears when the view isn't simply following output.
    private func viewportDidScroll(to position: Double) {
        view.viewportDidScroll()
        if position < 0.999 { view.overlay.flashScrollIndicator() }
    }

    // MARK: - Remote shells

    static func forgetRemoteHosts() {
        UserDefaults.standard.removeObject(forKey: alwaysHostsKey)
    }

    private static var alwaysHosts: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: alwaysHostsKey) ?? [])
    }

    /// Output arrived while a login command runs: once it settles on a shell prompt (not a
    /// password or yes/no question), ask whether to use Rune's input there, or set it up
    /// right away for hosts the user chose "Always" for.
    private func checkForRemotePrompt() {
        guard case .watching = remote else { return }
        promptCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .watching(let host) = self.remote, self.mode == .runningCommand else { return }
            let terminal = self.terminalView.getTerminal()
            guard !terminal.isCurrentBufferAlternate,
                  let line = terminal.getScrollInvariantLine(row: self.geometry.cursorPosition.row) else { return }
            let cursor = terminal.getCursorLocation()
            let text = line.translateToString(trimRight: false, startCol: 0, endCol: cursor.x)
            guard RemoteShell.looksLikeShellPrompt(text) else { return }
            if Self.alwaysHosts.contains(host) {
                self.setUpRemote(host: host)
            } else {
                self.remote = .offered(host: host)
                self.view.showRemoteOffer(host: host)
            }
        }
        promptCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// "Enable" / "Always for this host" on the offer.
    func acceptRemoteOffer(always: Bool) {
        guard case .offered(let host) = remote else { return }
        if always {
            var hosts = Self.alwaysHosts
            hosts.insert(host)
            UserDefaults.standard.set(Array(hosts).sorted(), forKey: Self.alwaysHostsKey)
        }
        view.hideRemoteOffer()
        setUpRemote(host: host)
    }

    /// "Not now": this connection stays a plain terminal.
    func declineRemoteOffer() {
        remote = .none
        view.hideRemoteOffer()
        view.focusPreferredResponder()
    }

    /// Types the setup script into the remote shell and hides its echo until it reports
    /// back. If it doesn't within a few seconds (another kind of shell), everything held
    /// back is shown and the session stays a plain terminal.
    private func setUpRemote(host: String) {
        guard state == .running else { return }
        remote = .settingUp(host: host)
        heldOutput = []
        // A line at a time, like typing: one big write overflows the terminal's input buffer
        // (about 1 KB), and the shell then sees a mangled script.
        let lines = RemoteShell.bootstrapScript.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.03) { [weak self] in
                guard let self, case .settingUp = self.remote else { return }
                self.terminalView.sendToShell(Array((line + "\r").utf8))
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, case .settingUp(let host) = self.remote else { return }
            self.releaseHeldOutput()
            self.remote = .none
            self.view.showRemoteFailure(host: host)
        }
        setupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private static let readyMarker = Array(RemoteShell.readyMarker.utf8)

    private func filterOutput(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard var held = heldOutput else { return slice }
        held.append(contentsOf: slice)
        if let range = held.firstRange(of: Self.readyMarker) {
            heldOutput = nil
            setupTimeout?.cancel()
            // What follows the marker (the remote host report and the new prompt) is shown.
            return held[range.upperBound...]
        }
        heldOutput = held
        return []
    }

    private func releaseHeldOutput() {
        guard let held = heldOutput else { return }
        heldOutput = nil
        if !held.isEmpty { terminalView.feed(byteArray: held[...]) }
    }

    /// Folder shown in the chips and block headers: `user@host:path` while remote.
    var displayDirectory: String {
        if case .active(let host) = remote { return host + ":" + (remoteDirectory ?? "~") }
        return currentDirectory
    }

    private func handleDataReceived() {
        if case .watching = remote { checkForRemotePrompt() }
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
        // Right away, so a taller terminal never shows its new blank rows for a frame.
        updateBottomTrim()
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
