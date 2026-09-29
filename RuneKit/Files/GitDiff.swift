import Foundation

/// One line of a unified diff, numbered in the old and new file.
public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `@@ … @@`: the start of a changed region (text is the function/context git shows).
        case hunk
        case context
        case added
        case removed
        /// "No newline at end of file", "Binary files differ"…
        case note
    }

    public let id: Int
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String
}

/// Changes to one file compared with the last commit.
public struct GitDiff: Equatable, Sendable {
    public var lines: [DiffLine]
    public var added: Int
    public var removed: Int
    /// The diff was longer than the limit and was cut.
    public var truncated: Bool

    /// Parses `git diff` output (file headers are skipped).
    public static func parse(_ output: String, maxLines: Int = 20_000) -> GitDiff {
        var lines: [DiffLine] = []
        var added = 0, removed = 0
        var old = 0, new = 0
        var inHunk = false
        var truncated = false
        func append(_ kind: DiffLine.Kind, _ oldNumber: Int?, _ newNumber: Int?, _ text: String) {
            lines.append(DiffLine(id: lines.count, kind: kind, oldNumber: oldNumber, newNumber: newNumber, text: text))
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= maxLines { truncated = true; break }
            let line = String(raw)
            if line.hasPrefix("@@") {
                guard let header = parseHunkHeader(line) else { continue }
                old = header.old
                new = header.new
                inHunk = true
                append(.hunk, nil, nil, header.context)
            } else if !inHunk || line.hasPrefix("diff --git ") {
                inHunk = false
                if line.hasPrefix("Binary files") { append(.note, nil, nil, "Binary file changed") }
            } else if line.hasPrefix("+") {
                added += 1
                append(.added, nil, new, String(line.dropFirst()))
                new += 1
            } else if line.hasPrefix("-") {
                removed += 1
                append(.removed, old, nil, String(line.dropFirst()))
                old += 1
            } else if line.hasPrefix(" ") {
                append(.context, old, new, String(line.dropFirst()))
                old += 1
                new += 1
            } else if line.hasPrefix("\\") {
                append(.note, nil, nil, String(line.dropFirst(2)))
            }
        }
        return GitDiff(lines: lines, added: added, removed: removed, truncated: truncated)
    }

    /// `@@ -12,7 +12,9 @@ func main()` → (12, 12, "func main()").
    static func parseHunkHeader(_ line: String) -> (old: Int, new: Int, context: String)? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ range: Substring) -> Int? { Int(range.dropFirst().split(separator: ",").first ?? "") }
        guard let old = start(parts[1]), let new = start(parts[2]) else { return nil }
        let context = parts.count > 4 ? String(parts[4]) : ""
        return (old, new, context)
    }

    /// `git diff --numstat` → added/removed line counts by absolute path (binary files and
    /// renames shown as `a => b` are left out).
    public static func parseNumstat(_ output: String, repoRoot: String) -> [String: LineCounts] {
        var counts: [String: LineCounts] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3, let added = Int(fields[0]), let removed = Int(fields[1]), !fields[2].contains(" => ") else { continue }
            counts[(repoRoot as NSString).appendingPathComponent(String(fields[2]))] = LineCounts(added: added, removed: removed)
        }
        return counts
    }
}

public struct LineCounts: Equatable, Sendable {
    public var added: Int
    public var removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }
}

/// Runs git without a shell. External diff tools and text converters are turned off, so
/// showing a diff never runs anything a repository configured.
public enum GitCommand {
    /// Runs `git -C repo <arguments>`; nil if git couldn't start.
    public static func run(_ arguments: [String], in repo: String, searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> (status: Int32, output: Data)? {
        let fm = FileManager.default
        let git = (searchPath.split(separator: ":").map { String($0) + "/git" } + ["/opt/homebrew/bin/git", "/usr/local/bin/git"])
            .first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repo, "-c", "core.quotepath=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// The changes to `path` since the last commit (staged and not), or the whole file as
    /// added when git doesn't track it yet. Runs git; call off the main thread.
    public static func diff(of path: String, in repo: String, untracked: Bool, searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> GitDiff? {
        let options = ["--no-color", "--no-ext-diff", "--no-textconv"]
        if untracked {
            // Exit status 1 means "there are differences".
            guard let result = run(["diff", "--no-index"] + options + ["--", "/dev/null", path], in: repo, searchPath: searchPath),
                  result.status <= 1 else { return nil }
            return GitDiff.parse(String(decoding: result.output, as: UTF8.self))
        }
        if let result = run(["diff", "HEAD"] + options + ["--", path], in: repo, searchPath: searchPath), result.status == 0 {
            return GitDiff.parse(String(decoding: result.output, as: UTF8.self))
        }
        // A repository without commits yet: what's staged.
        guard let result = run(["diff", "--cached"] + options + ["--", path], in: repo, searchPath: searchPath), result.status == 0 else { return nil }
        return GitDiff.parse(String(decoding: result.output, as: UTF8.self))
    }
}
