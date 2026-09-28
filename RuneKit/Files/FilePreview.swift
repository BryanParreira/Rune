import Foundation

/// Decides how a file can be shown inside Rune.
public enum FilePreview: Equatable, Sendable {
    case text(String, language: CodeLanguage, truncated: Bool)
    case image
    case binary
    case unreadable(String)

    /// Larger text files are shown up to this many bytes.
    public static let maxTextBytes = 2_000_000

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "icns", "ico", "pdf"]

    public static func load(path: String) -> FilePreview {
        let url = URL(fileURLWithPath: path)
        if imageExtensions.contains(url.pathExtension.lowercased()) { return .image }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unreadable("Rune doesn't have permission to read this file.")
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxTextBytes + 1) ?? Data()
        } catch {
            return .unreadable(error.localizedDescription)
        }
        let truncated = data.count > maxTextBytes
        let body = truncated ? data.prefix(maxTextBytes) : data
        if isBinary(body) { return .binary }
        let text = String(data: body, encoding: .utf8)
            ?? String(data: body.dropLast(min(3, body.count)), encoding: .utf8) // cut mid-character at the limit
            ?? String(decoding: body, as: UTF8.self)
        return .text(text, language: CodeLanguage.detect(fileName: url.lastPathComponent), truncated: truncated)
    }

    /// NUL bytes in the first 8 KB mean binary (the same heuristic git uses).
    public static func isBinary(_ data: Data) -> Bool {
        data.prefix(8_192).contains(0)
    }
}

/// Languages the viewer can color, with just enough syntax knowledge to do it well.
public enum CodeLanguage: String, Equatable, Sendable, CaseIterable {
    case swift, javascript, typescript, python, go, rust, c, java, kotlin, ruby, shell
    case json, yaml, toml, html, css, markdown, sql, plain

    public var displayName: String {
        switch self {
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .sql: return "SQL"
        case .c: return "C"
        case .plain: return "Plain Text"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public static func detect(fileName: String) -> CodeLanguage {
        let lower = fileName.lowercased()
        switch lower {
        case "makefile", "dockerfile", ".zshrc", ".bashrc", ".zprofile", ".zshenv", ".profile", ".bash_profile": return .shell
        default: break
        }
        switch (lower as NSString).pathExtension {
        case "swift": return .swift
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "tsx", "mts": return .typescript
        case "py", "pyw": return .python
        case "go": return .go
        case "rs": return .rust
        case "c", "h", "m", "mm", "cpp", "cc", "hpp", "cs": return .c
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "rb": return .ruby
        case "sh", "zsh", "bash", "fish", "command": return .shell
        case "json", "jsonc", "json5": return .json
        case "yml", "yaml": return .yaml
        case "toml", "ini", "conf", "cfg": return .toml
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard": return .html
        case "css", "scss", "less": return .css
        case "md", "markdown": return .markdown
        case "sql": return .sql
        default: return .plain
        }
    }

    var lineComments: [String] {
        switch self {
        case .python, .ruby, .shell, .yaml, .toml: return ["#"]
        case .sql: return ["--"]
        case .json, .html, .markdown, .plain, .css: return []
        default: return ["//"]
        }
    }

    var blockComments: [(String, String)] {
        switch self {
        case .html, .markdown: return [("<!--", "-->")]
        case .python, .ruby, .shell, .yaml, .toml, .json, .plain: return []
        default: return [("/*", "*/")]
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return ["let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "return", "if", "else", "guard", "for", "in", "while", "switch", "case", "default", "break", "continue", "private", "fileprivate", "public", "internal", "open", "static", "final", "init", "deinit", "self", "Self", "super", "nil", "true", "false", "throws", "throw", "try", "catch", "do", "async", "await", "some", "any", "where", "typealias", "override", "mutating", "weak", "lazy", "inout", "defer", "repeat", "is", "as", "@objc", "@Published", "@State", "@MainActor"]
        case .javascript, .typescript:
            return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "class", "extends", "new", "this", "super", "import", "export", "from", "as", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "yield", "delete", "void"]
        case .python:
            return ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "None", "True", "False", "async", "await", "self", "assert", "del"]
        case .go:
            return ["package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "chan", "select", "struct", "interface", "map", "type", "var", "const", "nil", "true", "false", "fallthrough", "goto"]
        case .rust:
            return ["fn", "let", "mut", "pub", "use", "mod", "struct", "enum", "impl", "trait", "for", "in", "if", "else", "match", "loop", "while", "return", "break", "continue", "self", "Self", "super", "crate", "const", "static", "async", "await", "move", "ref", "where", "true", "false", "as", "dyn", "unsafe", "type"]
        case .c, .java, .kotlin:
            return ["int", "char", "void", "float", "double", "long", "short", "unsigned", "signed", "const", "static", "struct", "union", "enum", "typedef", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "sizeof", "class", "public", "private", "protected", "new", "this", "null", "true", "false", "import", "package", "extends", "implements", "interface", "fun", "val", "var", "override", "try", "catch", "finally", "throw", "throws", "include", "define", "bool", "auto", "namespace", "using", "template", "nil", "YES", "NO", "self", "id"]
        case .ruby:
            return ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "nil", "true", "false", "self", "require", "attr_accessor", "puts", "then", "case", "when"]
        case .shell:
            return ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "export", "local", "source", "echo", "exit", "set", "unset", "alias", "readonly", "shift", "true", "false"]
        case .sql:
            return ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "and", "or", "not", "null", "as", "distinct", "primary", "key", "index", "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "JOIN", "ON", "GROUP", "BY", "ORDER", "AND", "OR", "NOT", "NULL", "AS"]
        case .json, .yaml, .toml:
            return ["true", "false", "null", "yes", "no"]
        case .css, .html, .markdown, .plain:
            return []
        }
    }
}

/// Fast, forgiving syntax coloring for the file viewer. It recognizes comments, strings,
/// numbers, keywords, capitalized type names, and a few structural tokens per language.
public enum CodeHighlighter {
    public enum Kind: Equatable, Sendable {
        case comment, string, number, keyword, type, tag, attribute, heading
    }

    public struct Token: Equatable, Sendable {
        public var range: NSRange
        public var kind: Kind
    }

    /// Only this many UTF-16 units are colored (huge files stay responsive).
    public static let maxHighlightedLength = 300_000

    public static func tokens(in text: String, language: CodeLanguage) -> [Token] {
        let ns = text as NSString
        let length = min(ns.length, maxHighlightedLength)
        guard length > 0, language != .plain else { return [] }
        if language == .markdown { return markdownTokens(ns, length: length) }

        var tokens: [Token] = []
        let keywords = language.keywords
        var i = 0
        func char(_ index: Int) -> unichar { index < length ? ns.character(at: index) : 0 }
        func matches(_ string: String, at index: Int) -> Bool {
            let utf16 = Array(string.utf16)
            guard index + utf16.count <= length else { return false }
            for (offset, unit) in utf16.enumerated() where ns.character(at: index + offset) != unit { return false }
            return true
        }
        func isIdentifierStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 64 }
        func isIdentifierPart(_ c: unichar) -> Bool { isIdentifierStart(c) || (c >= 48 && c <= 57) || (language == .css && c == 45) }

        outer: while i < length {
            let c = char(i)
            // Block comments.
            for (open, close) in language.blockComments where matches(open, at: i) {
                let start = i
                i += open.utf16.count
                while i < length, !matches(close, at: i) { i += 1 }
                i = min(length, i + close.utf16.count)
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
                continue outer
            }
            // Line comments.
            for marker in language.lineComments where matches(marker, at: i) {
                // In shell-like languages "#" starts a comment only at a word boundary ($#, ${#x} are not).
                if marker == "#", i > 0 {
                    let previous = char(i - 1)
                    if !(previous == 32 || previous == 9 || previous == 10) { break }
                }
                let start = i
                while i < length, char(i) != 10 { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
                continue outer
            }
            // Strings.
            if c == 34 || c == 39 || c == 96 { // " ' `
                // Apostrophes inside words aren't strings in prose-like languages.
                if c == 39, language == .html || language == .css {} else {
                    let start = i
                    let triple = (c == 34 || c == 39) && char(i + 1) == c && char(i + 2) == c
                    i += triple ? 3 : 1
                    while i < length {
                        let d = char(i)
                        if d == 92 { i += 2; continue } // backslash escape
                        if triple {
                            if d == c, char(i + 1) == c, char(i + 2) == c { i += 3; break }
                        } else {
                            if d == c { i += 1; break }
                            if d == 10, c != 96 { break } // unterminated single-line string
                        }
                        i += 1
                    }
                    i = min(i, length)
                    tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .string))
                    continue
                }
            }
            // Markup tags.
            if language == .html, c == 60 { // <
                let start = i
                i += 1
                if char(i) == 47 || char(i) == 33 || char(i) == 63 { i += 1 } // / ! ?
                while i < length, isIdentifierPart(char(i)) || char(i) == 58 || char(i) == 45 { i += 1 }
                if i > start + 1 { tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .tag)) }
                continue
            }
            // Numbers.
            if c >= 48 && c <= 57, i == 0 || !isIdentifierPart(char(i - 1)) {
                let start = i
                while i < length, (char(i) >= 48 && char(i) <= 57) || char(i) == 46 || char(i) == 95 || char(i) == 120
                        || (char(i) >= 97 && char(i) <= 102) || (char(i) >= 65 && char(i) <= 70) { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .number))
                continue
            }
            // Identifiers: keywords, types, keys.
            if isIdentifierStart(c) {
                let start = i
                i += 1
                while i < length, isIdentifierPart(char(i)) { i += 1 }
                let word = ns.substring(with: NSRange(location: start, length: i - start))
                let range = NSRange(location: start, length: i - start)
                if keywords.contains(word) {
                    tokens.append(Token(range: range, kind: .keyword))
                } else if language == .yaml || language == .toml, isKey(ns, from: i, length: length) {
                    tokens.append(Token(range: range, kind: .attribute))
                } else if language == .css, isKey(ns, from: i, length: length) {
                    tokens.append(Token(range: range, kind: .attribute))
                } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), word.count > 1 {
                    tokens.append(Token(range: range, kind: .type))
                }
                continue
            }
            i += 1
        }
        return tokens
    }

    /// True if the next non-space character is ":" or "=" (a key in YAML/TOML/CSS).
    private static func isKey(_ ns: NSString, from index: Int, length: Int) -> Bool {
        var j = index
        while j < length, ns.character(at: j) == 32 { j += 1 }
        guard j < length else { return false }
        let c = ns.character(at: j)
        return c == 58 || c == 61
    }

    private static func markdownTokens(_ ns: NSString, length: Int) -> [Token] {
        var tokens: [Token] = []
        var lineStart = 0
        var inFence = false
        while lineStart < length {
            var lineEnd = lineStart
            while lineEnd < length, ns.character(at: lineEnd) != 10 { lineEnd += 1 }
            let range = NSRange(location: lineStart, length: lineEnd - lineStart)
            let line = ns.substring(with: range)
            if line.hasPrefix("```") {
                inFence.toggle()
                tokens.append(Token(range: range, kind: .comment))
            } else if inFence {
                tokens.append(Token(range: range, kind: .string))
            } else if line.hasPrefix("#") {
                tokens.append(Token(range: range, kind: .heading))
            } else if line.hasPrefix(">") {
                tokens.append(Token(range: range, kind: .comment))
            } else {
                // Inline `code`.
                var i = lineStart
                while i < lineEnd {
                    if ns.character(at: i) == 96 {
                        var j = i + 1
                        while j < lineEnd, ns.character(at: j) != 96 { j += 1 }
                        if j < lineEnd {
                            tokens.append(Token(range: NSRange(location: i, length: j - i + 1), kind: .string))
                            i = j
                        }
                    }
                    i += 1
                }
            }
            lineStart = lineEnd + 1
        }
        return tokens
    }
}
