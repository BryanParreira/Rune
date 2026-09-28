import Foundation

/// Reads git state straight from `.git` so the prompt chip never spawns a process.
public enum GitInfo {
    /// Current branch name (or short commit for a detached HEAD) for the repo containing `path`.
    public static func branch(at path: String) -> String? {
        guard let gitDir = findGitDirectory(from: path),
              let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        return parseHead(head)
    }

    public static func parseHead(_ contents: String) -> String? {
        let head = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: ") {
            let ref = head.dropFirst(5)
            if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
            return String(ref)
        }
        guard head.count >= 7, head.allSatisfy(\.isHexDigit) else { return nil }
        return String(head.prefix(7))
    }

    /// Top-level folder of the repository containing `path` (the folder that holds `.git`).
    public static func repositoryRoot(for path: String) -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        for _ in 0..<64 {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    /// Walks up from `path` looking for `.git` (a directory, or a file pointing elsewhere for worktrees).
    static func findGitDirectory(from path: String) -> URL? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        for _ in 0..<64 {
            let candidate = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir) {
                if isDir.boolValue { return candidate }
                if let text = try? String(contentsOf: candidate, encoding: .utf8),
                   text.hasPrefix("gitdir: ") {
                    let target = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    return target.hasPrefix("/")
                        ? URL(fileURLWithPath: target, isDirectory: true)
                        : dir.appendingPathComponent(target, isDirectory: true).standardizedFileURL
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }
}
