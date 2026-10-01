import AppKit
import RuneKit

protocol CommandTextViewDelegate: AnyObject {
    func commandTextViewSubmit(_ view: CommandTextView)
    /// Return false if there was nothing older, so the caret can move normally.
    func commandTextView(_ view: CommandTextView, historyOlder current: String) -> Bool
    func commandTextViewHistoryNewer(_ view: CommandTextView) -> Bool
    func commandTextViewComplete(_ view: CommandTextView)
    func commandTextViewCancel(_ view: CommandTextView)
    func commandTextViewInterrupt(_ view: CommandTextView)
    func commandTextViewEndOfInput(_ view: CommandTextView)
    func commandTextViewClearScreen(_ view: CommandTextView)
    func commandTextViewAskAI(_ view: CommandTextView)
    /// ⌘C with no text selected; return false if there's nothing else to copy.
    func commandTextViewCopyWithoutSelection(_ view: CommandTextView) -> Bool
    func commandTextViewCanCopyWithoutSelection(_ view: CommandTextView) -> Bool
}

/// Native multi-line command editor: Enter runs, Shift-Enter inserts a newline,
/// Up/Down at the first/last line walk history, Tab completes paths.
final class CommandTextView: NSTextView {
    static let defaultPlaceholder = "Cast a command…"

    weak var commandDelegate: CommandTextViewDelegate?
    var placeholder = CommandTextView.defaultPlaceholder { didSet { needsDisplay = true } }
    private var placeholderColor: NSColor = .tertiaryLabelColor
    /// Grey completion shown after the caret (from history), accepted with → / End / ⌃E / ⌃F.
    var suggestionSuffix: String? { didSet { if oldValue != suggestionSuffix { needsDisplay = true } } }
    /// Set while a workflow from the palette is being filled in: Tab jumps between its
    /// `{{placeholders}}` and Return won't run it until they're all replaced.
    var fillingWorkflow = false
    /// ⌥B / ⌥F / ⌥D / ⌥. act as in a shell instead of typing ∫ ƒ ∂ ≥ (the "Option as Meta"
    /// setting, like the terminal).
    var optionAsMeta = true
    /// What ⌃U, ⌃W and ⌃K removed, for ⌃Y.
    private var killBuffer = ""
    /// ⌥. pressed again right away steps to the previous command's last argument.
    private var lastArgument: (offset: Int, range: NSRange)?

    convenience init() {
        // TextKit 1: line heights and the suggestion overlay use the layout manager directly.
        self.init(usingTextLayoutManager: false)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
    }

    func configure(font: NSFont, palette: ChromePalette) {
        self.font = font
        textColor = palette.text
        insertionPointColor = palette.accent
        placeholderColor = palette.hint
        selectedTextAttributes = [.backgroundColor: palette.accent.withAlphaComponent(0.3)]
        typingAttributes = [.font: font, .foregroundColor: palette.text]
        needsDisplay = true
    }

    var lineHeight: CGFloat {
        guard let font else { return 16 }
        return layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender + font.leading)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let font else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: placeholderColor]
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: attrs)
        } else if let suffix = suggestionSuffix, let point = endOfTextPoint() {
            (suffix as NSString).draw(at: point, withAttributes: attrs)
        }
    }

    /// Where the next character after the text would be drawn.
    private func endOfTextPoint() -> NSPoint? {
        guard let layoutManager, let textContainer else { return nil }
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: length - 1, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return NSPoint(x: rect.maxX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y)
    }

    private var caretAtEnd: Bool {
        selectedRange().length == 0 && selectedRange().location == (string as NSString).length
    }

    /// Accepts the whole suggestion, or just its next word.
    private func acceptSuggestion(wordOnly: Bool) -> Bool {
        guard caretAtEnd, let suffix = suggestionSuffix, !suffix.isEmpty else { return false }
        var chunk = suffix
        if wordOnly {
            let trimmed = suffix.drop(while: { $0 == " " })
            let leading = suffix.count - trimmed.count
            let word = trimmed.prefix(while: { $0 != " " })
            chunk = String(suffix.prefix(leading + word.count))
        }
        insertText(chunk, replacementRange: selectedRange())
        return true
    }

    override var acceptsFirstResponder: Bool { true }

    override func didChangeText() {
        super.didChangeText()
        if string.isEmpty { fillingWorkflow = false }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.subtracting([.numericPad, .function, .capsLock]).isEmpty
        let key = event.charactersIgnoringModifiers?.lowercased()
        let cyclingLastArgument = lastArgument
        lastArgument = nil
        if handleShellKey(key, mods: mods, cycling: cyclingLastArgument) { return }

        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if mods == .command {
                commandDelegate?.commandTextViewAskAI(self)
            } else if mods.contains(.shift) || mods.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if plain {
                if fillingWorkflow, let placeholder = Workflow.placeholderRanges(in: string).first {
                    setSelectedRange(placeholder)
                    scrollRangeToVisible(placeholder)
                    return
                }
                fillingWorkflow = false
                commandDelegate?.commandTextViewSubmit(self)
            } else {
                super.keyDown(with: event)
            }
            return
        case 126 where plain: // Up
            if isCaretOnFirstLine, commandDelegate?.commandTextView(self, historyOlder: string) == true { return }
        case 125 where plain: // Down
            if isCaretOnLastLine, commandDelegate?.commandTextViewHistoryNewer(self) == true { return }
        case 124 where plain || mods == .function || mods == [.function, .numericPad]: // Right
            if acceptSuggestion(wordOnly: false) { return }
        case 124 where mods.contains(.option):
            if acceptSuggestion(wordOnly: true) { return }
        case 119: // End
            if acceptSuggestion(wordOnly: false) { return }
        case 48 where plain: // Tab
            if fillingWorkflow {
                let selection = selectedRange()
                if let next = Workflow.nextPlaceholder(in: string, from: selection.location + selection.length) {
                    setSelectedRange(next)
                    return
                }
                fillingWorkflow = false
            }
            commandDelegate?.commandTextViewComplete(self)
            return
        case 53: // Escape
            commandDelegate?.commandTextViewCancel(self)
            return
        default:
            break
        }

        if mods == .control, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "c":
                commandDelegate?.commandTextViewInterrupt(self)
                return
            case "d" where string.isEmpty:
                commandDelegate?.commandTextViewEndOfInput(self)
                return
            case "l":
                commandDelegate?.commandTextViewClearScreen(self)
                return
            case "r":
                // Like the shell's reverse history search, but over commands and their output.
                NSApp.sendAction(#selector(MainWindowController.showRecall(_:)), to: nil, from: self)
                return
            case "e", "f":
                if acceptSuggestion(wordOnly: false) { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - Shell editing keys

    /// Line-editing keys from shells (readline/zle) that terminal users type without thinking.
    private func handleShellKey(_ key: String?, mods: NSEvent.ModifierFlags, cycling: (offset: Int, range: NSRange)?) -> Bool {
        guard let key, !hasMarkedText() else { return false }
        let text = string as NSString
        let caret = selectedRange().location
        if mods == .control {
            switch key {
            case "u": // to the start of the line
                let line = text.lineRange(for: NSRange(location: caret, length: 0))
                kill(NSRange(location: line.location, length: caret - line.location))
                return true
            case "w": // the word before the caret
                kill(ShellWords.wordBeforeCaret(in: string, caret: caret))
                return true
            case "k": // to the end of the line (or the line break, at its end)
                var end = NSMaxRange(text.lineRange(for: NSRange(location: caret, length: 0)))
                if end > caret, text.character(at: end - 1) == 0x0A, end - 1 > caret { end -= 1 }
                kill(NSRange(location: caret, length: end - caret))
                return true
            case "y":
                guard !killBuffer.isEmpty else { return true }
                insertText(killBuffer, replacementRange: selectedRange())
                return true
            case "p":
                if isCaretOnFirstLine, commandDelegate?.commandTextView(self, historyOlder: string) == true { return true }
                return false
            case "n":
                if isCaretOnLastLine, commandDelegate?.commandTextViewHistoryNewer(self) == true { return true }
                return false
            default:
                return false
            }
        }
        guard optionAsMeta, mods == .option else { return false }
        switch key {
        case "b": moveWordBackward(nil)
        case "f": moveWordForward(nil)
        case "d": deleteWordForward(nil)
        case ".": insertLastArgument(after: cycling)
        default: return false
        }
        return true
    }

    private func kill(_ range: NSRange) {
        guard range.length > 0 else { return }
        killBuffer = (string as NSString).substring(with: range)
        insertText("", replacementRange: range)
    }

    /// ⌥.: the last argument of the previous command; again for the one before.
    private func insertLastArgument(after previous: (offset: Int, range: NSRange)?) {
        let commands = HistoryStore.shared.history.entries
        var offset = previous.map { $0.offset + 1 } ?? 0
        while offset < commands.count {
            if let argument = ShellWords.lastArgument(of: commands[commands.count - 1 - offset]) {
                let target = previous?.range ?? selectedRange()
                insertText(argument, replacementRange: target)
                lastArgument = (offset, NSRange(location: target.location, length: (argument as NSString).length))
                return
            }
            offset += 1
        }
        // Nothing older: keep the last one in place so another ⌥. still does nothing odd.
        if let previous { lastArgument = previous }
        NSSound.beep()
    }

    /// Paste as plain text only.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// With nothing selected in the editor, ⌘C copies the selected block (⌘↑).
    override func copy(_ sender: Any?) {
        if selectedRange().length == 0, commandDelegate?.commandTextViewCopyWithoutSelection(self) == true { return }
        super.copy(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), selectedRange().length == 0 {
            return commandDelegate?.commandTextViewCanCopyWithoutSelection(self) ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    private var caretLocation: Int { selectedRange().location }

    private var isCaretOnFirstLine: Bool {
        let text = string as NSString
        let before = text.substring(to: min(caretLocation, text.length))
        return !before.contains("\n")
    }

    private var isCaretOnLastLine: Bool {
        let text = string as NSString
        let location = min(caretLocation + selectedRange().length, text.length)
        let after = text.substring(from: location)
        return !after.contains("\n")
    }
}
