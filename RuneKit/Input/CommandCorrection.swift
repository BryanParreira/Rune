import Foundation

/// Suggests a fix for a command that failed because of a typo. Only ever suggests: the user
/// puts it in the input (Tab) and runs it themselves.
public enum CommandCorrection {
    /// A corrected command, or nil. `output` is the end of the failed command's output;
    /// `directories` lists folders in the working directory (for `cd` typos).
    public static func suggest(command: String, exitCode: Int32?, output: String,
                               knownCommands: Set<String>, directories: [String] = []) -> String? {
        guard let exitCode, exitCode != 0 else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        var words = trimmed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let first = words.first else { return nil }
        let text = output.suffix(4_000)

        // The tool names the fix itself.
        if let fixed = gitSuggestion(in: text, words: words) ?? npmSuggestion(in: String(text)) { return fixed == trimmed ? nil : fixed }

        // Unknown command: the closest known one.
        if text.contains("command not found") || exitCode == 127 {
            guard !knownCommands.contains(first), let best = closest(to: first, in: knownCommands) else { return nil }
            words[0] = best
            return words.joined(separator: " ")
        }

        // cd into a folder that doesn't exist: a similar folder here.
        if first == "cd", words.count == 2, text.contains("no such file or directory") || text.contains("No such file or directory") {
            guard let best = closest(to: words[1], in: Set(directories)) else { return nil }
            return "cd " + best
        }

        // Mistyped subcommand of a tool Rune knows (brew isntall, docker pss).
        if words.count >= 2, let spec = CommandSpecs.all[first], !spec.subcommands.isEmpty,
           !spec.subcommands.contains(where: { $0.name == words[1] || $0.aliases.contains(words[1]) }),
           text.lowercased().contains("unknown") || text.lowercased().contains("not a") || text.lowercased().contains("invalid"),
           let best = closest(to: words[1], in: Set(spec.subcommands.map(\.name))) {
            words[1] = best
            return words.joined(separator: " ")
        }
        return nil
    }

    /// `git: 'comit' is not a git command. … The most similar command is\n\tcommit`
    private static func gitSuggestion(in text: Substring, words: [String]) -> String? {
        guard words.first == "git", words.count >= 2, text.contains("is not a git command") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(where: { $0.contains("most similar command") }),
              marker + 1 < lines.count else { return nil }
        let fix = lines[marker + 1].trimmingCharacters(in: .whitespaces)
        guard !fix.isEmpty, !fix.contains(" ") else { return nil }
        var fixed = words
        fixed[1] = fix
        return fixed.joined(separator: " ")
    }

    /// `Did you mean this?\n    npm install`
    private static func npmSuggestion(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(where: { $0.contains("Did you mean this?") }), marker + 1 < lines.count else { return nil }
        let fix = lines[marker + 1].trimmingCharacters(in: .whitespaces)
        return fix.hasPrefix("npm ") ? fix : nil
    }

    /// The closest candidate within a small edit distance (≤1 for short words, ≤2 otherwise).
    /// Ties prefer a candidate with the same letters (a swap: gti → git), then the same first
    /// letter, then the shorter name, then alphabetical, so the result is always the same.
    static func closest(to word: String, in candidates: Set<String>) -> String? {
        guard word.count >= 2 else { return nil }
        let limit = word.count <= 4 ? 1 : 2
        let letters = word.sorted()
        let scored = candidates.compactMap { candidate -> (Int, Int, Int, Int, String)? in
            guard abs(candidate.count - word.count) <= limit else { return nil }
            let distance = editDistance(word, candidate)
            guard distance <= limit else { return nil }
            return (distance, candidate.sorted() == letters ? 0 : 1, candidate.first == word.first ? 0 : 1, candidate.count, candidate)
        }
        return scored.min { $0 < $1 }?.4
    }

    /// Damerau-Levenshtein (adjacent swaps count as one edit: gti → git).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
