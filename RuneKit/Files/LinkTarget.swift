import Foundation

/// What a ⌘-clicked link in the output points at: a URL, or a file (optionally at a line and
/// column, as in compiler errors: `src/app.ts:42:7`).
public enum LinkTarget: Equatable, Sendable {
    case url(URL)
    case file(path: String, line: Int?, column: Int?)

    /// Resolves `link` against the folders the output may have come from (newest first). A
    /// file link is returned only if the file exists in one of them.
    public static func resolve(_ link: String, folders: [String], home: String = NSHomeDirectory(),
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> LinkTarget? {
        let trimmed = link.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`()[]<>,;"))
        guard !trimmed.isEmpty else { return nil }
        // `README.md:27` parses as a URL with the scheme "readme.md": only `scheme://…` (and
        // mailto:) count as links.
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme != "file", scheme.count > 1,
           trimmed.contains("://") || scheme == "mailto" {
            return .url(url)
        }
        var path = trimmed.hasPrefix("file://") ? (URL(string: trimmed)?.path ?? trimmed) : trimmed
        // Trailing :line or :line:column (a trailing colon is punctuation).
        var line: Int?
        var column: Int?
        if path.hasSuffix(":") { path.removeLast() }
        let parts = path.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3, let l = Int(parts[parts.count - 2]), let c = Int(parts[parts.count - 1]) {
            line = l
            column = c
            path = parts.dropLast(2).joined(separator: ":")
        } else if parts.count >= 2, let l = Int(parts[parts.count - 1]) {
            line = l
            path = parts.dropLast().joined(separator: ":")
        }
        if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        let candidates = path.hasPrefix("/") ? [path] : folders.map { ($0 as NSString).appendingPathComponent(path) }
        for candidate in candidates {
            let standardized = (candidate as NSString).standardizingPath
            if fileExists(standardized) { return .file(path: standardized, line: line, column: column) }
        }
        return nil
    }
}

/// Editors that can open a file at a line, by the URL scheme they register.
public enum EditorLink {
    /// URL that opens `path` at `line`/`column` in the editor with `bundleIdentifier`, or nil
    /// if that editor has no such scheme (open the file normally then).
    public static func url(bundleIdentifier: String, path: String, line: Int, column: Int?) -> URL? {
        let position = column.map { ":\(line):\($0)" } ?? ":\(line)"
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        switch bundleIdentifier {
        case "com.microsoft.VSCode": return URL(string: "vscode://file\(encoded)\(position)")
        case "com.microsoft.VSCodeInsiders": return URL(string: "vscode-insiders://file\(encoded)\(position)")
        case "com.todesktop.230313mzl4w4u92": return URL(string: "cursor://file\(encoded)\(position)")
        case "com.exafunction.windsurf": return URL(string: "windsurf://file\(encoded)\(position)")
        case "dev.zed.Zed", "dev.zed.Zed-Preview": return URL(string: "zed://file\(encoded)\(position)")
        default: return nil
        }
    }
}
