import Foundation

/// Lightweight shell syntax highlighting for the input editor, in the spirit of
/// zsh-syntax-highlighting: commands green when they exist, red when they don't; strings,
/// options, variables, operators, and comments get their own colors.
public enum CommandHighlighter {
    public enum Kind: Equatable, Sendable {
        case command
        case unknownCommand
        case argument
        case option
        case string
        case variable
        case operatorToken
        case comment
    }

    public struct Token: Equatable, Sendable {
        /// UTF-16 range in the input.
        public var range: NSRange
        public var kind: Kind
    }

    /// Words that are valid in command position without being executables.
    public static let reservedWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
        "in", "function", "select", "time", "coproc", "!", "{", "}", "[[", "]]",
    ]

    public static func tokenize(_ text: String, isCommand: (String) -> Bool) -> [Token] {
        let chars = Array(text.utf16)
        var tokens: [Token] = []
        var i = 0
        var expectCommand = true

        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A }
        func isOperator(_ c: UInt16) -> Bool { c == 0x7C || c == 0x26 || c == 0x3B || c == 0x3C || c == 0x3E || c == 0x28 || c == 0x29 }

        while i < chars.count {
            let c = chars[i]
            if isSpace(c) {
                if c == 0x0A { expectCommand = true }
                i += 1
                continue
            }
            // Comment to end of line (only at a word start).
            if c == 0x23 { // #
                var j = i
                while j < chars.count, chars[j] != 0x0A { j += 1 }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .comment))
                i = j
                continue
            }
            if isOperator(c) {
                var j = i + 1
                while j < chars.count, isOperator(chars[j]) { j += 1 }
                let op = String(utf16CodeUnits: Array(chars[i..<j]), count: j - i)
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .operatorToken))
                // After |, &&, ||, ;, ( a new command starts; after redirections a filename follows.
                expectCommand = !(op.hasPrefix(">") || op.hasPrefix("<") || op.hasSuffix(">") || op == "&>")
                i = j
                continue
            }

            // A word: runs until unquoted whitespace/operator. Quoted parts become string tokens.
            let wordStart = i
            var j = i
            var pieces: [Token] = []
            var plainStart = i
            while j < chars.count, !isSpace(chars[j]), !isOperator(chars[j]) {
                let ch = chars[j]
                if ch == 0x5C { j = min(j + 2, chars.count); continue } // backslash escape
                if ch == 0x27 || ch == 0x22 { // ' or "
                    if j > plainStart { pieces.append(Token(range: NSRange(location: plainStart, length: j - plainStart), kind: .argument)) }
                    let quote = ch
                    var k = j + 1
                    while k < chars.count, chars[k] != quote {
                        if quote == 0x22, chars[k] == 0x5C { k += 1 }
                        k += 1
                    }
                    k = min(k + 1, chars.count)
                    pieces.append(Token(range: NSRange(location: j, length: k - j), kind: .string))
                    j = k
                    plainStart = j
                    continue
                }
                if ch == 0x24 { // $VAR / ${...} / $(...)
                    if j > plainStart { pieces.append(Token(range: NSRange(location: plainStart, length: j - plainStart), kind: .argument)) }
                    var k = j + 1
                    if k < chars.count, chars[k] == 0x7B { // {
                        while k < chars.count, chars[k] != 0x7D { k += 1 }
                        k = min(k + 1, chars.count)
                    } else {
                        while k < chars.count, isVariableChar(chars[k]) { k += 1 }
                    }
                    pieces.append(Token(range: NSRange(location: j, length: max(1, k - j)), kind: .variable))
                    j = max(k, j + 1)
                    plainStart = j
                    continue
                }
                j += 1
            }
            if j > plainStart { pieces.append(Token(range: NSRange(location: plainStart, length: j - plainStart), kind: .argument)) }

            let word = String(utf16CodeUnits: Array(chars[wordStart..<j]), count: j - wordStart)
            if expectCommand {
                if isAssignment(word) {
                    tokens.append(Token(range: NSRange(location: wordStart, length: j - wordStart), kind: .variable))
                    // Still expecting the command after `FOO=bar`.
                } else {
                    let valid = reservedWords.contains(word) || isCommand(unescape(word))
                    tokens.append(Token(range: NSRange(location: wordStart, length: j - wordStart), kind: valid ? .command : .unknownCommand))
                    // Keywords like `if`/`then`/`do` are followed by another command.
                    expectCommand = ["if", "then", "else", "elif", "do", "while", "until", "time", "!", "{", "sudo", "exec", "command", "builtin", "nohup", "env", "xargs"].contains(word)
                }
            } else if word.hasPrefix("-") && pieces.count == 1 {
                tokens.append(Token(range: NSRange(location: wordStart, length: j - wordStart), kind: .option))
            } else {
                tokens.append(contentsOf: pieces)
            }
            i = j
        }
        return tokens
    }

    static func isVariableChar(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
            || c == 0x3F || c == 0x40 || c == 0x23 || c == 0x2A // $? $@ $# $*
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func unescape(_ word: String) -> String {
        word.replacingOccurrences(of: "\\", with: "")
    }
}

/// Knows which command names exist: executables on PATH, plus shell builtins and the
/// aliases/functions reported by the shell.
public final class CommandCatalog: @unchecked Sendable {
    public static let builtins: Set<String> = [
        "alias", "autoload", "bg", "bindkey", "break", "builtin", "bye", "cd", "chdir", "command",
        "compdef", "continue", "declare", "dirs", "disown", "echo", "emulate", "eval", "exec", "exit",
        "export", "false", "fc", "fg", "float", "functions", "getopts", "hash", "history", "integer",
        "jobs", "kill", "let", "limit", "local", "logout", "noglob", "popd", "print", "printf", "pushd",
        "pwd", "r", "read", "readonly", "rehash", "return", "set", "setopt", "shift", "source", "suspend",
        "test", "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unfunction",
        "unhash", "unlimit", "unset", "unsetopt", "vared", "wait", "whence", "where", "which", "zle",
        "zmodload", "zparseopts", "zstyle", ".", ":", "[",
    ]

    private let lock = NSLock()
    private var executables: Set<String> = []
    private var _shellPath: String?

    /// The PATH the user's shell reported (nil until the integration has run).
    public var shellPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return _shellPath
    }
    private var shellNames: Set<String> = []

    public init() {}

    /// Scans PATH directories (call off the main thread). With `onlyIfEmpty`, the result is
    /// discarded if another load already filled the catalog (used for an early best-effort seed).
    public func loadExecutables(path: String, onlyIfEmpty: Bool = false) {
        var names = Set<String>()
        let fm = FileManager.default
        for dir in path.split(separator: ":") {
            guard let entries = try? fm.contentsOfDirectory(atPath: String(dir)) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                names.insert(entry)
            }
        }
        lock.lock()
        if !(onlyIfEmpty && !executables.isEmpty) {
            executables = names
            if !onlyIfEmpty { _shellPath = path }
        }
        lock.unlock()
    }

    /// Aliases and functions defined in the user's shell (reported by the integration).
    public func setShellNames(_ names: Set<String>) {
        lock.lock()
        shellNames = names
        lock.unlock()
    }

    public func contains(_ name: String) -> Bool {
        if name.isEmpty { return false }
        if name.contains("/") {
            let expanded = name.hasPrefix("~/") ? NSHomeDirectory() + name.dropFirst(1) : name
            return FileManager.default.isExecutableFile(atPath: expanded)
        }
        if Self.builtins.contains(name) { return true }
        lock.lock()
        defer { lock.unlock() }
        return executables.contains(name) || shellNames.contains(name)
    }

    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !executables.isEmpty
    }
}

extension CommandHistory {
    /// The most recent entry that starts with `prefix` (and is longer), like zsh-autosuggestions.
    public func suggestion(for prefix: String) -> String? {
        guard !prefix.isEmpty, !prefix.hasPrefix(" ") else { return nil }
        return entries.last { $0.count > prefix.count && $0.hasPrefix(prefix) }
    }
}
