import AppKit

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
}

/// Native multi-line command editor: Enter runs, Shift-Enter inserts a newline,
/// Up/Down at the first/last line walk history, Tab completes paths.
final class CommandTextView: NSTextView {
    static let defaultPlaceholder = "Cast a command…"

    weak var commandDelegate: CommandTextViewDelegate?
    var placeholder = CommandTextView.defaultPlaceholder { didSet { needsDisplay = true } }
    private var placeholderColor: NSColor = .tertiaryLabelColor

    convenience init() {
        self.init(frame: .zero)
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
        guard string.isEmpty, let font else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: placeholderColor]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: attrs)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.subtracting([.numericPad, .function, .capsLock]).isEmpty

        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if mods.contains(.shift) || mods.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if plain {
                commandDelegate?.commandTextViewSubmit(self)
            } else {
                super.keyDown(with: event)
            }
            return
        case 126 where plain: // Up
            if isCaretOnFirstLine, commandDelegate?.commandTextView(self, historyOlder: string) == true { return }
        case 125 where plain: // Down
            if isCaretOnLastLine, commandDelegate?.commandTextViewHistoryNewer(self) == true { return }
        case 48 where plain: // Tab
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
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// Paste as plain text only.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
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
