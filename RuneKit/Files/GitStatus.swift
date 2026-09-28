import Foundation

/// Working-tree status for the file tree (from `git status --porcelain=v1 -z`).
public enum GitFileState: Equatable, Sendable {
    case modified
    case added
    case untracked
    case deleted
    case renamed
    case conflicted
    case ignored

    /// Single-letter badge like editors show.
    public var badge: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .untracked: return "U"
        case .deleted: return "D"
        case .renamed: return "R"
        case .conflicted: return "!"
        case .ignored: return ""
        }
    }

    /// When a folder contains several kinds of changes, show the most important one.
    var priority: Int {
        switch self {
        case .conflicted: return 6
        case .modified: return 5
        case .deleted: return 4
        case .renamed: return 3
        case .added: return 2
        case .untracked: return 1
        case .ignored: return 0
        }
    }
}

public struct GitStatusSnapshot: Equatable, Sendable {
    /// Absolute path → state, for files and (aggregated) their parent folders.
    public var states: [String: GitFileState] = [:]

    public init(states: [String: GitFileState] = [:]) {
        self.states = states
    }

    public func state(for path: String) -> GitFileState? { states[path] }

    /// Parses NUL-separated porcelain v1 output. `repoRoot` is the repository's top level.
    public static func parse(porcelain: Data, repoRoot: String) -> GitStatusSnapshot {
        let fields = porcelain.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [String: GitFileState] = [:]
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard field.count > 3 else { continue }
            let x = field[field.startIndex]
            let y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))
            let state: GitFileState
            switch (x, y) {
            case ("?", "?"): state = .untracked
            case ("!", "!"): state = .ignored
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): state = .conflicted
            case ("R", _), ("C", _):
                state = .renamed
                index += 1 // the original path follows as its own field
            case ("A", _): state = .added
            case ("D", _), (_, "D"): state = .deleted
            default: state = .modified
            }
            guard state != .ignored else { continue }
            let absolute = (repoRoot as NSString).appendingPathComponent(path.hasSuffix("/") ? String(path.dropLast()) : path)
            files[absolute] = state
        }

        // Folders take the most important state of anything inside them.
        var states = files
        for (path, state) in files {
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count >= repoRoot.count, parent != "/" {
                if let existing = states[parent], existing.priority >= state.priority { break }
                states[parent] = state
                if parent == repoRoot { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return GitStatusSnapshot(states: states)
    }
}
