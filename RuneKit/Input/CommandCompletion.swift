import Foundation

/// Completes subcommands, flags and project-specific values (npm scripts, make targets, git
/// branches) for well-known tools. Anything it doesn't know falls back to path completion.
public enum CommandCompletion {
    public struct Suggestion: Equatable, Sendable {
        public var name: String
        public var description: String?

        public init(_ name: String, _ description: String? = nil) {
            self.name = name
            self.description = description
        }
    }

    public struct Result: Equatable, Sendable {
        /// UTF-16 range of the word being completed.
        public var range: NSRange
        /// The single match plus a space, or the longest common prefix.
        public var replacement: String
        public var suggestions: [Suggestion]
        public var isUnique: Bool { suggestions.count == 1 }
    }

    /// Project data the engine can ask for (injected so tests don't touch the disk).
    public struct Sources {
        public var packageScripts: (String) -> [String]
        public var makeTargets: (String) -> [String]
        public var gitBranches: (String) -> [String]

        public init(packageScripts: @escaping (String) -> [String], makeTargets: @escaping (String) -> [String],
                    gitBranches: @escaping (String) -> [String]) {
            self.packageScripts = packageScripts
            self.makeTargets = makeTargets
            self.gitBranches = gitBranches
        }

        public static let live = Sources(
            packageScripts: ProjectInfo.packageScripts(in:),
            makeTargets: ProjectInfo.makeTargets(in:),
            gitBranches: ProjectInfo.gitBranches(in:)
        )
    }

    /// Nil when the word isn't an argument of a known tool (use path completion instead).
    public static func complete(text: String, cursor: Int, cwd: String, sources: Sources = .live) -> Result? {
        let ns = text as NSString
        let cursor = min(max(cursor, 0), ns.length)
        // Only the current command matters: stop at the last separator before the cursor.
        let before = ns.substring(to: cursor)
        let segment = before.components(separatedBy: CharacterSet(charactersIn: "|;&")).last ?? before
        let words = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let endsWithSpace = segment.last == " "
        let current = endsWithSpace ? "" : (words.last ?? "")
        let previous = endsWithSpace ? words : Array(words.dropLast())
        guard let tool = previous.first, let spec = CommandSpecs.all[tool] else { return nil }

        // Walk into subcommands already typed (`git remote add`, `docker compose up`).
        var node = spec
        var positional: [String] = []
        for word in previous.dropFirst() where !word.hasPrefix("-") {
            if let sub = node.subcommands.first(where: { $0.name == word || $0.aliases.contains(word) }) {
                node = sub
            } else {
                positional.append(word)
            }
        }

        var options: [Suggestion]
        if current.hasPrefix("-") {
            options = node.flags.map { Suggestion($0.name, $0.description) }
        } else if !node.subcommands.isEmpty, positional.isEmpty {
            options = node.subcommands.map { Suggestion($0.name, $0.description) }
        } else if let values = node.values {
            options = values(sources, cwd).map { Suggestion($0) }
        } else {
            return nil
        }

        let matches = options.filter { $0.name.hasPrefix(current) }
        guard !matches.isEmpty else { return nil }
        let range = NSRange(location: cursor - (current as NSString).length, length: (current as NSString).length)
        let replacement: String
        if matches.count == 1 {
            replacement = matches[0].name + " "
        } else {
            replacement = commonPrefix(matches.map(\.name))
        }
        return Result(range: range, replacement: replacement.count >= current.count ? replacement : current, suggestions: matches)
    }

    static func commonPrefix(_ names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) { prefix.removeLast() }
        }
        return prefix
    }
}

/// Reads project files for completion values. Cheap and bounded: small files, short timeouts.
public enum ProjectInfo {
    /// Script names from package.json in `directory`.
    public static func packageScripts(in directory: String) -> [String] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any]
        else { return [] }
        return scripts.keys.sorted()
    }

    /// Targets defined in the Makefile in `directory` (not pattern rules or variables).
    public static func makeTargets(in directory: String) -> [String] {
        for name in ["GNUmakefile", "makefile", "Makefile"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return parseMakeTargets(text)
        }
        return []
    }

    public static func parseMakeTargets(_ text: String) -> [String] {
        var targets: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard let first = line.first, first != "\t", first != "#", first != " ", first != ".",
                  let colon = line.firstIndex(of: ":") else { continue }
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") { continue } // `VAR := value`
            let names = line[..<colon].split(separator: " ").map(String.init)
            for name in names where !name.contains("%") && !name.contains("$") && !name.contains("=") {
                if !targets.contains(name) { targets.append(name) }
            }
        }
        return targets
    }

    /// Local and remote branch names for the repository at `directory`.
    public static func gitBranches(in directory: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline { usleep(5_000) }
        if process.isRunning { process.terminate(); return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") && $0 != "origin" }
    }
}
