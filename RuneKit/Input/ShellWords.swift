import Foundation

/// Word boundaries the way a shell's line editor sees them (whitespace-separated, quotes kept
/// together), for ⌃W and ⌥. in the input editor.
public enum ShellWords {
    /// The last argument of a command line, with its quotes: `git commit -m "fix it"` → `"fix it"`.
    /// Nil for a command without arguments.
    public static func lastArgument(of command: String) -> String? {
        let words = split(command)
        return words.count > 1 ? words.last : nil
    }

    /// Splits on unquoted whitespace, keeping quoted parts (and escapes) inside their word.
    public static func split(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                current.append(character)
                escaped = true
            } else if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                current.append(character)
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The range ⌃W deletes before `caret` (UTF-16 offset): the whitespace right before it,
    /// then the word before that, like readline's unix-word-rubout.
    public static func wordBeforeCaret(in text: String, caret: Int) -> NSRange {
        let string = text as NSString
        var start = min(caret, string.length)
        let isSpace: (unichar) -> Bool = { $0 == 0x20 || $0 == 0x09 }
        while start > 0, isSpace(string.character(at: start - 1)) { start -= 1 }
        while start > 0, !isSpace(string.character(at: start - 1)), string.character(at: start - 1) != 0x0A { start -= 1 }
        return NSRange(location: start, length: min(caret, string.length) - start)
    }
}
