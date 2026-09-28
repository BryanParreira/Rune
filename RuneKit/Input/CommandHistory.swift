import Foundation

/// Command history: the user's zsh history file plus this session's commands.
public struct CommandHistory: Sendable {
    /// Oldest first, unique (the most recent occurrence wins).
    public private(set) var entries: [String] = []
    public var limit: Int

    public init(entries: [String] = [], limit: Int = 10_000) {
        self.limit = limit
        for entry in entries { append(entry) }
    }

    public mutating func append(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = entries.lastIndex(of: trimmed) {
            entries.remove(at: existing)
        }
        entries.append(trimmed)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// Location of the zsh history file: $HISTFILE, else $ZDOTDIR/.zsh_history, else ~/.zsh_history.
    public static func zshHistoryURL(environment: [String: String], home: URL) -> URL {
        if let file = environment["HISTFILE"], file.hasPrefix("/") {
            return URL(fileURLWithPath: file)
        }
        if let zdotdir = environment["ZDOTDIR"], zdotdir.hasPrefix("/") {
            return URL(fileURLWithPath: zdotdir).appendingPathComponent(".zsh_history")
        }
        return home.appendingPathComponent(".zsh_history")
    }

    /// Parses a zsh history file (plain or EXTENDED_HISTORY format, possibly metafied).
    public static func parseZshHistory(_ data: Data) -> [String] {
        let text = String(decoding: unmetafy(data), as: UTF8.self)
        var commands: [String] = []
        var current: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if current == nil {
                // ": 1700000000:0;command"
                if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                    let meta = line[line.index(line.startIndex, offsetBy: 2)..<semi]
                    if meta.allSatisfy({ $0.isNumber || $0 == ":" }) {
                        line = String(line[line.index(after: semi)...])
                    }
                }
            }
            // A trailing backslash continues the command on the next line.
            if line.hasSuffix("\\") {
                current = (current.map { $0 + "\n" } ?? "") + line.dropLast()
                continue
            }
            let full = (current.map { $0 + "\n" } ?? "") + line
            current = nil
            if !full.trimmingCharacters(in: .whitespaces).isEmpty {
                commands.append(full)
            }
        }
        if let current, !current.isEmpty { commands.append(current) }
        return commands
    }

    /// zsh stores bytes 0x83–0x9F (and NUL) as 0x83 followed by the byte XOR 0x20.
    static func unmetafy(_ data: Data) -> Data {
        guard data.contains(0x83) else { return data }
        var out = Data()
        out.reserveCapacity(data.count)
        var escape = false
        for byte in data {
            if escape {
                out.append(byte ^ 0x20)
                escape = false
            } else if byte == 0x83 {
                escape = true
            } else {
                out.append(byte)
            }
        }
        return out
    }
}

/// Up/Down navigation through history, preserving what the user was typing.
public struct HistoryNavigator: Sendable {
    private var index: Int?
    private var draft = ""

    public init() {}

    public var isBrowsing: Bool { index != nil }

    /// Older entry, or nil if already at the oldest.
    public mutating func older(in history: CommandHistory, current: String) -> String? {
        let entries = history.entries
        guard !entries.isEmpty else { return nil }
        if let index {
            guard index > 0 else { return nil }
            self.index = index - 1
        } else {
            draft = current
            self.index = entries.count - 1
        }
        return self.index.map { entries[$0] }
    }

    /// Newer entry; past the newest returns the saved draft. Nil if not browsing.
    public mutating func newer(in history: CommandHistory) -> String? {
        guard let index else { return nil }
        let entries = history.entries
        if index + 1 < entries.count {
            self.index = index + 1
            return entries[index + 1]
        }
        self.index = nil
        return draft
    }

    public mutating func reset() {
        index = nil
        draft = ""
    }
}
