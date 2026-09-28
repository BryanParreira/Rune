import AppKit
import RuneKit
import SwiftUI

/// Bottom input area: context chips, the command editor, and a hint line.
final class InputAreaView: NSView, NSTextViewDelegate {
    weak var sessionView: SessionView?

    private let chipsModel = InputChromeModel()
    private let chipsHost: NSHostingView<ContextChipsRow>
    private let hintHost: NSHostingView<InputHintLine>
    private let scrollView = NSScrollView()
    let editor = CommandTextView()
    private var editorHeight: NSLayoutConstraint?
    private var leading: NSLayoutConstraint?
    private var trailing: NSLayoutConstraint?
    private var palette: ChromePalette?
    private var running = false

    static let maxVisibleLines = 10

    override init(frame frameRect: NSRect) {
        chipsHost = NSHostingView(rootView: ContextChipsRow(model: chipsModel))
        hintHost = NSHostingView(rootView: InputHintLine(model: chipsModel))
        super.init(frame: frameRect)
        wantsLayer = true

        for host in [chipsHost, hintHost] as [NSView] {
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
        }
        chipsHost.sizingOptions = [.intrinsicContentSize]
        hintHost.sizingOptions = [.intrinsicContentSize]
        chipsHost.safeAreaRegions = []
        hintHost.safeAreaRegions = []

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.documentView = editor
        addSubview(scrollView)

        editor.delegate = self
        editor.commandDelegate = self
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true

        let leading = chipsHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        let trailing = scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        let editorHeight = scrollView.heightAnchor.constraint(equalToConstant: 20)
        self.leading = leading
        self.trailing = trailing
        self.editorHeight = editorHeight

        NSLayoutConstraint.activate([
            chipsHost.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            leading,
            chipsHost.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: chipsHost.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: chipsHost.leadingAnchor),
            trailing,
            editorHeight,

            hintHost.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            hintHost.leadingAnchor.constraint(equalTo: chipsHost.leadingAnchor),
            hintHost.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            hintHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let palette else { return }
        palette.background.setFill()
        bounds.fill()
        palette.outline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        focusEditor()
    }

    // MARK: - Configuration

    func apply(snapshot: ConfigSnapshot, palette: ChromePalette) {
        self.palette = palette
        let config = snapshot.config
        leading?.constant = CGFloat(config.paddingX)
        trailing?.constant = -CGFloat(config.paddingX)
        chipsModel.palette = palette
        chipsModel.monoFontSize = CGFloat(config.fontSize)
        editor.configure(font: snapshot.font, palette: palette)
        refreshHighlighting()
        updateEditorHeight()
        needsDisplay = true
    }

    func updateContext(directory: String, branch: String?) {
        let display = TabTitle.abbreviate(path: directory, home: NSHomeDirectory())
        if chipsModel.directory != display { chipsModel.directory = display }
        if chipsModel.branch != branch { chipsModel.branch = branch }
    }

    func setRunning(_ running: Bool, command: String?) {
        self.running = running
        editor.isEditable = !running
        editor.alphaValue = running ? 0.45 : 1
        editor.placeholder = running ? "Running \(command.map { "“\($0)”" } ?? "command")…"
            : (aiConversationOpen ? "Ask a follow-up (⌘↵) or type a command…" : CommandTextView.defaultPlaceholder)
        chipsModel.hint = currentHint
        editor.needsDisplay = true
    }

    func focusEditor() {
        guard let window, !isHidden, !running else { return }
        if window.firstResponder !== editor {
            window.makeFirstResponder(editor)
        }
    }

    /// Keys typed into the terminal view while the editor owns input.
    func receiveRedirected(_ data: ArraySlice<UInt8>) {
        focusEditor()
        switch Array(data) {
        case [13]:
            submit()
        case [127], [8]:
            editor.deleteBackward(nil)
        default:
            // Printable text only; escape sequences (arrows etc.) are dropped.
            guard !data.contains(where: { $0 < 0x20 || $0 == 0x7F }),
                  let text = String(bytes: data, encoding: .utf8) else { return }
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
    }

    // MARK: - Editor sizing

    /// Shows follow-up hints while an AI answer is open.
    var aiConversationOpen = false {
        didSet {
            guard oldValue != aiConversationOpen else { return }
            chipsModel.hint = currentHint
            if !running {
                editor.placeholder = aiConversationOpen ? "Ask a follow-up (⌘↵) or type a command…" : CommandTextView.defaultPlaceholder
            }
        }
    }

    private var currentHint: InputChromeModel.Hint {
        if running { return .running }
        if aiConversationOpen { return .aiOpen }
        return editor.string.isEmpty ? .idle : .typing
    }

    func textDidChange(_ notification: Notification) {
        chipsModel.completions = []
        chipsModel.hint = currentHint
        sessionView?.session?.resetHistoryNavigation()
        refreshHighlighting()
        updateSuggestion()
        updateEditorHeight()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateSuggestion()
    }

    /// Colors the command line like zsh-syntax-highlighting.
    func refreshHighlighting() {
        guard let palette, let storage = editor.textStorage, let font = editor.font else { return }
        let text = editor.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        let tokens = CommandHighlighter.tokenize(text) { CommandCatalog.shared.contains($0) }
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: palette.text], range: full)
        for token in tokens where NSMaxRange(token.range) <= full.length {
            let color: NSColor
            switch token.kind {
            case .command: color = palette.success
            case .unknownCommand: color = palette.error
            case .argument: continue
            case .option: color = palette.ansiCyan
            case .string: color = palette.ansiYellow
            case .variable: color = palette.ansiMagenta
            case .operatorToken: color = palette.secondary
            case .comment: color = palette.hint
            }
            storage.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        storage.endEditing()
    }

    /// History-based suggestion shown in grey after the caret (like zsh-autosuggestions).
    private func updateSuggestion() {
        let text = editor.string
        let atEnd = editor.selectedRange().length == 0 && editor.selectedRange().location == (text as NSString).length
        guard atEnd, !running, !text.contains("\n"),
              let match = HistoryStore.shared.history.suggestion(for: text)
        else {
            editor.suggestionSuffix = nil
            return
        }
        editor.suggestionSuffix = String(match.dropFirst(text.count))
    }

    private func updateEditorHeight() {
        guard let layoutManager = editor.layoutManager, let container = editor.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let lineHeight = editor.lineHeight
        let used = layoutManager.usedRect(for: container).height
        let lines = max(1, min(Self.maxVisibleLines, Int((used / lineHeight).rounded(.up))))
        editorHeight?.constant = CGFloat(lines) * lineHeight
        scrollView.hasVerticalScroller = used > CGFloat(Self.maxVisibleLines) * lineHeight
        editor.scrollRangeToVisible(editor.selectedRange())
    }

    // MARK: - Commands

    fileprivate func submit() {
        guard let session = sessionView?.session else { return }
        let command = editor.string
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.submit(command)
        editor.string = ""
        chipsModel.completions = []
        textDidChange(Notification(name: NSText.didChangeNotification))
    }
}

extension InputAreaView: CommandTextViewDelegate {
    func commandTextViewSubmit(_ view: CommandTextView) {
        submit()
    }

    func commandTextView(_ view: CommandTextView, historyOlder current: String) -> Bool {
        guard let session = sessionView?.session, let entry = session.historyOlder(current: current) else { return false }
        setEditorText(entry)
        return true
    }

    func commandTextViewHistoryNewer(_ view: CommandTextView) -> Bool {
        guard let session = sessionView?.session, let entry = session.historyNewer() else { return false }
        setEditorText(entry)
        return true
    }

    private func setEditorText(_ text: String) {
        editor.string = text
        refreshHighlighting()
        editor.suggestionSuffix = nil
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        chipsModel.hint = text.isEmpty ? .idle : .typing
        updateEditorHeight()
    }

    func commandTextViewComplete(_ view: CommandTextView) {
        guard let session = sessionView?.session else { return }
        let cursor = editor.selectedRange().location
        guard let result = session.complete(text: editor.string, cursor: cursor) else {
            NSSound.beep()
            return
        }
        let current = (editor.string as NSString).substring(with: result.range)
        if result.replacement != current {
            editor.insertText(result.replacement, replacementRange: result.range)
        }
        chipsModel.completions = result.isUnique ? [] : result.candidates
    }

    func commandTextViewAskAI(_ view: CommandTextView) {
        guard let sessionView, let session = sessionView.session else { return }
        let text = editor.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // ⌘↵ on an empty line runs a finished suggestion, like pressing its Run button.
            if sessionView.conversation.isCollapsed {
                sessionView.conversation.expand()
            } else if sessionView.conversation.state == .done, let command = sessionView.conversation.command {
                session.submit(command)
            }
            return
        }
        session.askAI(text)
        editor.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    /// Inserts text at the caret (e.g. a path from the file tree).
    func insertAtCaret(_ text: String) {
        focusEditor()
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func setText(_ text: String) {
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textDidChange(Notification(name: NSText.didChangeNotification))
        focusEditor()
    }

    func commandTextViewCancel(_ view: CommandTextView) {
        if let conversation = sessionView?.conversation, conversation.isVisible {
            conversation.isActive ? conversation.stop() : conversation.dismiss()
            return
        }
        if !chipsModel.completions.isEmpty {
            chipsModel.completions = []
        } else {
            sessionView?.session?.clearBlockSelection()
        }
    }

    func commandTextViewInterrupt(_ view: CommandTextView) {
        // Ctrl-C at the prompt clears the line, like a shell.
        editor.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func commandTextViewEndOfInput(_ view: CommandTextView) {
        sessionView?.session?.sendEOF()
    }

    func commandTextViewClearScreen(_ view: CommandTextView) {
        sessionView?.session?.clearScreen()
    }
}

// MARK: - SwiftUI chrome

final class InputChromeModel: ObservableObject {
    enum Hint { case idle, typing, running, aiOpen }

    @Published var directory = "~"
    @Published var branch: String?
    @Published var palette = ChromePalette(theme: .runeDark)
    @Published var monoFontSize: CGFloat = 13
    @Published var hint: Hint = .idle
    @Published var completions: [String] = []
}

struct ContextChipsRow: View {
    @ObservedObject var model: InputChromeModel
    @ObservedObject var ai = AIService.shared

    var body: some View {
        HStack(spacing: 8) {
            ContextChip(symbol: "folder", text: model.directory, palette: model.palette, size: model.monoFontSize - 1)
            if let branch = model.branch {
                ContextChip(symbol: "arrow.triangle.branch", text: branch, palette: model.palette, size: model.monoFontSize - 1)
            }
            if let active = ai.activeModel {
                Button(action: showModelMenu) {
                    ContextChip(symbol: "sparkle", text: active, palette: model.palette, size: model.monoFontSize - 1)
                }
                .buttonStyle(.plain)
                .help("AI model (⌘↵ to ask). Click to switch.")
                if !ai.endpoint.isLocal {
                    ContextChip(symbol: "exclamationmark.triangle", text: "remote AI: \(ai.endpoint.url.host ?? "")", palette: model.palette, size: model.monoFontSize - 1)
                        .help("AI requests go to \(ai.endpoint.url.absoluteString), not this Mac.")
                }
            }
        }
        .fixedSize()
    }

    private func showModelMenu() {
        let menu = NSMenu()
        for installed in ai.status.models {
            let title = [installed.name, installed.displaySize.map { "  \($0)" }].compactMap { $0 }.joined()
            let item = ClosureMenuItem(title: title) { AIService.shared.select(model: installed.name) }
            item.state = installed.name == ai.activeModel ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Refresh Models") { AIService.shared.refresh() })
        menu.addItem(ClosureMenuItem(title: "AI Settings…") {
            NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
        })
        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: location.x - 10, y: location.y + 10), in: nil)
    }
}

struct ContextChip: View {
    let symbol: String
    let text: String
    let palette: ChromePalette
    let size: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: size - 1))
                .foregroundColor(Color(nsColor: palette.secondary))
            Text(text)
                .font(.system(size: size, design: .monospaced))
                .foregroundColor(Color(nsColor: palette.text))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color(nsColor: palette.foreground.withAlphaComponent(0.16)), lineWidth: 1)
        )
    }
}

struct InputHintLine: View {
    @ObservedObject var model: InputChromeModel
    @ObservedObject var ai = AIService.shared

    var body: some View {
        Group {
            if !model.completions.isEmpty {
                Text(model.completions.prefix(40).joined(separator: "   "))
                    .foregroundColor(Color(nsColor: model.palette.secondary))
            } else {
                switch model.hint {
                case .idle:
                    hint(ai.isEnabled ? "↑ history   ⌘↵ ask AI   ⇧↵ new line   ⇥ complete   ⌘↑ blocks"
                                      : "↑ history   ⇧↵ new line   ⇥ complete   ⌘↑ blocks")
                case .typing:
                    hint(ai.isEnabled ? "↵ run   ⌘↵ ask AI   → accept suggestion   ⇧↵ new line"
                                      : "↵ run   → accept suggestion   ⇧↵ new line   ⇥ complete")
                case .running:
                    hint("⌃C interrupt   keystrokes go to the running program")
                case .aiOpen:
                    hint("⌘↵ follow up   ↵ run as command   esc close")
                }
            }
        }
        .font(.system(size: max(9, model.monoFontSize - 2), design: .monospaced))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func hint(_ text: String) -> some View {
        Text(text).foregroundColor(Color(nsColor: model.palette.hint))
    }
}
