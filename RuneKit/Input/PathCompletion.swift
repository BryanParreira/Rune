import Foundation

/// File/directory completion for the word under the cursor, relative to a working directory.
/// Designed to be replaced by a richer engine later: callers only see `Result`.
public enum PathCompletion {
    public struct Result: Equatable, Sendable {
        /// UTF-16 range in the input text to replace.
        public var range: NSRange
        /// Text to insert (the single match, or the longest common prefix).
        public var replacement: String
        /// All matching names (display form, dirs end in "/"). Empty if nothing matched.
        public var candidates: [String]
        public var isUnique: Bool { candidates.count == 1 }
    }

    public static func complete(
        text: String,
        cursor: Int,
        cwd: String,
        home: String,
        listDirectory: (String) -> [(name: String, isDirectory: Bool)] = PathCompletion.listDirectory
    ) -> Result? {
        let ns = text as NSString
        let cursor = min(max(cursor, 0), ns.length)

        // Walk back to the start of the word, honoring backslash-escaped spaces.
        var start = cursor
        while start > 0 {
            let ch = ns.character(at: start - 1)
            if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x7C || ch == 0x3B || ch == 0x26 {
                if start >= 2 && ns.character(at: start - 2) == 0x5C { // "\ "
                    start -= 2
                    continue
                }
                break
            }
            start -= 1
        }
        let word = ns.substring(with: NSRange(location: start, length: cursor - start))
        let unescaped = unescape(word)

        let (dirPart, prefix): (String, String)
        if let slash = unescaped.lastIndex(of: "/") {
            dirPart = String(unescaped[...slash])
            prefix = String(unescaped[unescaped.index(after: slash)...])
        } else {
            dirPart = ""
            prefix = unescaped
        }

        let searchDir: String
        if dirPart.hasPrefix("~/") || dirPart == "~/" {
            searchDir = home + "/" + dirPart.dropFirst(2)
        } else if dirPart.hasPrefix("/") {
            searchDir = dirPart
        } else {
            searchDir = cwd + "/" + dirPart
        }

        let showHidden = prefix.hasPrefix(".")
        let matches = listDirectory(searchDir)
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .filter { prefix.isEmpty || $0.name.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !matches.isEmpty else { return nil }

        let candidates = matches.map { $0.name + ($0.isDirectory ? "/" : "") }
        let replacementCore: String
        if matches.count == 1 {
            replacementCore = candidates[0]
        } else {
            replacementCore = longestCommonPrefix(matches.map(\.name), caseInsensitive: true) ?? prefix
        }
        // Keep the user's own spelling of the prefix when the common prefix doesn't extend it.
        let core = replacementCore.count > prefix.count ? replacementCore : prefix
        var replacement = escape(dirPart) + escape(core)
        if matches.count == 1 && !matches[0].isDirectory {
            replacement += " "
        }
        return Result(range: NSRange(location: start, length: cursor - start), replacement: replacement, candidates: candidates)
    }

    public static func listDirectory(_ path: String) -> [(name: String, isDirectory: Bool)] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        return items.prefix(5_000).map { item in
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (item.lastPathComponent, isDir)
        }
    }

    /// What picking `candidate` (a name from `Result.candidates`) puts in place of `word`, the
    /// text the result's range covered: the folder part as typed, the escaped name, and a space
    /// after a file (a folder keeps its "/" so completion can continue inside it).
    public static func insertion(for candidate: String, replacing word: String) -> String {
        var folder = ""
        if let slash = word.lastIndex(of: "/") { folder = String(word[...slash]) }
        return folder + escape(candidate) + (candidate.hasSuffix("/") ? "" : " ")
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if " '\"()&;|<>$`\\!*?[]{}#".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var escaping = false
        for ch in s {
            if escaping {
                out.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    static func longestCommonPrefix(_ names: [String], caseInsensitive: Bool) -> String? {
        guard var prefix = names.first else { return nil }
        for name in names.dropFirst() {
            var common = ""
            for (a, b) in zip(prefix, name) {
                let same = caseInsensitive ? a.lowercased() == b.lowercased() : a == b
                guard same else { break }
                common.append(a)
            }
            prefix = common
        }
        return prefix
    }
}
