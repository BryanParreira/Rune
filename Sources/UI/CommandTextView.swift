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
            case "e", "f":
                if acceptSuggestion(wordOnly: false) { return }
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
