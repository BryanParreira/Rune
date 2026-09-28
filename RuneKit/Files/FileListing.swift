import Foundation

/// Directory listing for the file tree sidebar: folders first, then files, natural order.
public enum FileListing {
    public struct Entry: Equatable, Hashable, Sendable, Identifiable {
        public var name: String
        public var path: String
        public var isDirectory: Bool
        public var isHidden: Bool
        public var isSymlink: Bool

        public var id: String { path }

        public init(name: String, path: String, isDirectory: Bool, isHidden: Bool, isSymlink: Bool = false) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
            self.isHidden = isHidden
            self.isSymlink = isSymlink
        }

        public var fileExtension: String {
            (name as NSString).pathExtension.lowercased()
        }
    }

    /// Noise that clutters a project tree; shown only when hidden files are on.
    public static let noiseNames: Set<String> = [".DS_Store", ".git", ".localized"]

    /// Upper bound per folder so huge directories (node_modules…) stay responsive.
    public static let maxEntries = 3_000

    public static func entries(at path: String, showHidden: Bool) -> [Entry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        let entries: [Entry] = items.prefix(maxEntries * 2).compactMap { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let name = item.lastPathComponent
            let hidden = name.hasPrefix(".") || (values?.isHidden ?? false)
            var isDirectory = values?.isDirectory ?? false
            let isSymlink = values?.isSymbolicLink ?? false
            if isSymlink {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) { isDirectory = isDir.boolValue }
            }
            return Entry(name: name, path: item.path, isDirectory: isDirectory, isHidden: hidden, isSymlink: isSymlink)
        }
        return Array(sorted(filter(entries, showHidden: showHidden)).prefix(maxEntries))
    }

    public static func filter(_ entries: [Entry], showHidden: Bool) -> [Entry] {
        showHidden ? entries : entries.filter { !$0.isHidden && !noiseNames.contains($0.name) }
    }

    public static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Shell-safe single-quoted path for inserting into a command.
    public static func shellQuoted(_ path: String) -> String {
        if path.allSatisfy({ $0.isLetter || $0.isNumber || "/._-+~".contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
