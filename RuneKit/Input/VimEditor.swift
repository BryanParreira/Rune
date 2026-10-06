import Foundation

/// Vim keys for a one-command input: normal and insert mode, motions (h l w b e 0 ^ $),
/// operators with motions (d c y + w b e $ 0 ^, dd cc yy, iw), x X D C S r ~ p P, and counts.
/// Pure text in, text out; the editor applies the result. Positions are UTF-16 offsets, like
/// NSTextView's.
public struct VimEditor: Sendable {
    public enum Mode: Equatable, Sendable { case insert, normal }

    /// What the editor should do besides showing the new text.
    public enum Action: Equatable, Sendable {
        case none
        case undo
        case historyOlder
        case historyNewer
        /// Esc in normal mode: the editor's usual Esc (close a panel, clear a selection).
        case cancel
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        public var caret: Int
        public var action: Action = .none

        public init(text: String, caret: Int, action: Action = .none) {
            self.text = text
            self.caret = caret
            self.action = action
        }
    }

    public private(set) var mode: Mode = .insert
    /// Text yanked or deleted last (the unnamed register).
    public var register: String = ""
    /// Keys waiting for the rest of a command ("d", "2d", "r", "di"…).
    public private(set) var pending: String = ""

    public init() {}

    /// Esc in insert mode: back to normal mode, the caret moving onto the last character typed.
    public mutating func enterNormal(text: String, caret: Int) -> Result {
        mode = .normal
        pending = ""
        let chars = Array(text)
        let index = Self.charIndex(utf16: caret, in: text)
        return Result(text: text, caret: Self.utf16(Self.clampNormal(index - 1, count: chars.count), in: chars))
    }

    /// Leaves normal mode without a key (e.g. the input was cleared after running a command).
    public mutating func reset() {
        mode = .insert
        pending = ""
    }

    /// Handles one typed key in normal mode. Nil: not a Vim key (the editor handles it as usual).
    public mutating func handle(key: String, text: String, caret: Int) -> Result? {
        guard mode == .normal, key.count == 1 else { return nil }
        var chars = Array(text)
        var index = Self.clampNormal(Self.charIndex(utf16: caret, in: text), count: chars.count)
        func result(_ action: Action = .none) -> Result {
            Result(text: String(chars), caret: Self.utf16(index, in: chars), action: action)
        }

        // r<char>: replace the character under the caret.
        if pending.hasSuffix("r") {
            let count = Self.count(in: String(pending.dropLast()))
            pending = ""
            guard index + count <= chars.count, !chars.isEmpty else { return result() }
            for offset in 0..<count { chars[index + offset] = Character(key) }
            index += count - 1
            return result()
        }

        // Counts: 3w, 2dd, d2w.
        if let digit = key.first, digit.isNumber, digit != "0" || pending.last?.isNumber == true {
            pending += key
            return result()
        }

        let operatorPending = pending.first(where: { "dcy".contains($0) })
        if let op = operatorPending {
            let prefix = pending
            pending = ""
            let count = Self.count(in: prefix.filter(\.isNumber))
            // dd cc yy: the whole input.
            if String(op) == key {
                register = String(chars)
                if op == "y" { return result() }
                chars.removeAll()
                index = 0
                if op == "c" { mode = .insert }
                return result()
            }
            // iw / aw: the word under the caret.
            if prefix.hasSuffix("i") || prefix.hasSuffix("a") {
                guard key == "w", !chars.isEmpty else { return result() }
                var range = Self.wordRange(at: index, in: chars)
                if prefix.hasSuffix("a") {
                    while range.upperBound < chars.count, chars[range.upperBound] == " " { range = range.lowerBound..<(range.upperBound + 1) }
                }
                apply(op, range: range, chars: &chars, index: &index)
                return result()
            }
            if key == "i" || key == "a" {
                pending = prefix + key
                return result()
            }
            // cw on a word changes to the end of that word, not into the space after it.
            if op == "c", key == "w" || key == "W", index < chars.count, !chars[index].isWhitespace {
                var end = index
                for _ in 0..<count {
                    end = key == "w" ? Self.wordRange(at: end, in: chars).upperBound
                                     : (chars[end...].firstIndex(where: \.isWhitespace) ?? chars.count)
                    if count > 1 { end = min(chars.count - 1, Self.nextWordStart(from: end, in: chars)) }
                }
                apply(op, range: index..<max(index + 1, end), chars: &chars, index: &index)
                return result()
            }
            guard let target = motion(key, from: index, in: chars, count: count, forOperator: true) else { return result() }
            let range = min(index, target)..<max(index, target)
            apply(op, range: range, chars: &chars, index: &index)
            return result()
        }

        let count = Self.count(in: pending)
        pending = ""
        if let target = motion(key, from: index, in: chars, count: count, forOperator: false) {
            index = Self.clampNormal(target, count: chars.count)
            return result()
        }
        switch key {
        case "d", "c", "y", "r":
            pending = (count > 1 ? String(count) : "") + key
        case "i":
            mode = .insert
        case "a":
            mode = .insert
            index = min(chars.count, index + (chars.isEmpty ? 0 : 1))
        case "I":
            mode = .insert
            index = Self.firstNonBlank(in: chars)
        case "A":
            mode = .insert
            index = chars.count
        case "x":
            guard !chars.isEmpty else { break }
            let end = min(chars.count, index + count)
            register = String(chars[index..<end])
            chars.removeSubrange(index..<end)
            index = Self.clampNormal(index, count: chars.count)
        case "X":
            let start = max(0, index - count)
            guard start < index else { break }
            register = String(chars[start..<index])
            chars.removeSubrange(start..<index)
            index = start
        case "D", "C":
            register = String(chars[min(index, chars.count)...])
            chars.removeSubrange(min(index, chars.count)...)
            if key == "C" {
                mode = .insert
                index = chars.count
            } else {
                index = Self.clampNormal(index, count: chars.count)
            }
        case "S":
            register = String(chars)
            chars.removeAll()
            index = 0
            mode = .insert
        case "s":
            guard !chars.isEmpty else { mode = .insert; break }
            register = String(chars[index])
            chars.remove(at: index)
            mode = .insert
        case "p", "P":
            guard !register.isEmpty else { break }
            let at = key == "p" && !chars.isEmpty ? index + 1 : index
            let pasted = Array(String(repeating: register, count: count))
            chars.insert(contentsOf: pasted, at: min(at, chars.count))
            index = Self.clampNormal(min(at, chars.count) + pasted.count - 1, count: chars.count)
        case "~":
            guard !chars.isEmpty else { break }
            let end = min(chars.count, index + count)
            for i in index..<end {
                let c = String(chars[i])
                chars[i] = Character(c == c.uppercased() ? c.lowercased() : c.uppercased())
            }
            index = Self.clampNormal(end, count: chars.count)
        case "u":
            return result(.undo)
        case "k":
            return result(.historyOlder)
        case "j":
            return result(.historyNewer)
        default:
            // Any other printable key does nothing in normal mode (it never types).
            break
        }
        return result()
    }

    /// Esc in normal mode, or Esc with an operator pending.
    public mutating func escapeInNormal(text: String, caret: Int) -> Result {
        let hadPending = !pending.isEmpty
        pending = ""
        return Result(text: text, caret: caret, action: hadPending ? .none : .cancel)
    }

    private mutating func apply(_ op: Character, range: Range<Int>, chars: inout [Character], index: inout Int) {
        let lower = max(0, min(range.lowerBound, chars.count))
        let clamped = lower..<max(lower, min(chars.count, range.upperBound))
        guard !clamped.isEmpty else {
            if op == "c" { mode = .insert }
            return
        }
        register = String(chars[clamped])
        switch op {
        case "y":
            index = clamped.lowerBound
        case "c":
            chars.removeSubrange(clamped)
            index = clamped.lowerBound
            mode = .insert
        default:
            chars.removeSubrange(clamped)
            index = Self.clampNormal(clamped.lowerBound, count: chars.count)
        }
    }

    // MARK: Motions

    /// Where a motion lands, or nil when `key` isn't a motion. For operators, `e` and `$`
    /// include the character they land on.
    private func motion(_ key: String, from index: Int, in chars: [Character], count: Int, forOperator: Bool) -> Int? {
        var position = index
        switch key {
        case "h":
            return max(0, index - count)
        case "l", " ":
            return min(forOperator ? chars.count : max(0, chars.count - 1), index + count)
        case "0":
            return 0
        case "^":
            return Self.firstNonBlank(in: chars)
        case "$":
            return forOperator ? chars.count : max(0, chars.count - 1)
        case "w", "W":
            for _ in 0..<count { position = Self.nextWordStart(from: position, in: chars, bigWord: key == "W") }
            return position
        case "b", "B":
            for _ in 0..<count { position = Self.previousWordStart(from: position, in: chars, bigWord: key == "B") }
            return position
        case "e", "E":
            for _ in 0..<count { position = Self.wordEnd(from: position, in: chars, bigWord: key == "E") }
            return forOperator ? min(chars.count, position + 1) : position
        default:
            return nil
        }
    }

    private enum CharClass { case space, word, punctuation }

    private static func charClass(_ c: Character, bigWord: Bool) -> CharClass {
        if c.isWhitespace { return .space }
        if bigWord || c.isLetter || c.isNumber || c == "_" { return .word }
        return .punctuation
    }

    static func nextWordStart(from index: Int, in chars: [Character], bigWord: Bool = false) -> Int {
        guard index < chars.count else { return chars.count }
        var i = index
        let start = charClass(chars[i], bigWord: bigWord)
        while i < chars.count, charClass(chars[i], bigWord: bigWord) == start, start != .space { i += 1 }
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        return i
    }

    static func previousWordStart(from index: Int, in chars: [Character], bigWord: Bool = false) -> Int {
        var i = index
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }
        guard i > 0 else { return 0 }
        let cls = charClass(chars[i - 1], bigWord: bigWord)
        while i > 0, charClass(chars[i - 1], bigWord: bigWord) == cls { i -= 1 }
        return i
    }

    static func wordEnd(from index: Int, in chars: [Character], bigWord: Bool = false) -> Int {
        var i = index + 1
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count else { return max(0, chars.count - 1) }
        let cls = charClass(chars[i], bigWord: bigWord)
        while i + 1 < chars.count, charClass(chars[i + 1], bigWord: bigWord) == cls { i += 1 }
        return i
    }

    static func wordRange(at index: Int, in chars: [Character]) -> Range<Int> {
        guard index < chars.count else { return chars.count..<chars.count }
        let cls = charClass(chars[index], bigWord: false)
        var start = index, end = index + 1
        while start > 0, charClass(chars[start - 1], bigWord: false) == cls { start -= 1 }
        while end < chars.count, charClass(chars[end], bigWord: false) == cls { end += 1 }
        return start..<end
    }

    private static func firstNonBlank(in chars: [Character]) -> Int {
        chars.firstIndex { !$0.isWhitespace } ?? 0
    }

    // MARK: Helpers

    private static func count(in digits: String) -> Int {
        max(1, min(9_999, Int(digits) ?? 1))
    }

    /// In normal mode the caret sits on a character, never after the last one.
    private static func clampNormal(_ index: Int, count: Int) -> Int {
        max(0, min(index, count - 1))
    }

    /// The character at a UTF-16 offset (one inside a character, like the middle of an
    /// emoji, counts as that character).
    static func charIndex(utf16 offset: Int, in text: String) -> Int {
        var consumed = 0
        for (index, character) in text.enumerated() {
            let width = character.utf16.count
            if offset < consumed + width { return index }
            consumed += width
        }
        return text.count
    }

    static func utf16(_ index: Int, in chars: [Character]) -> Int {
        chars.prefix(max(0, min(index, chars.count))).reduce(0) { $0 + $1.utf16.count }
    }
}
