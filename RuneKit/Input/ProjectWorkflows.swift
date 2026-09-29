import Foundation

/// Workflows shared through a repository: `.rune/workflows.json` in the project (found by
/// walking up from the current folder, stopping at the home folder). The file is either a
/// list of workflows or `{"workflows": [...]}`, in the same format as config.json.
/// Workflows only ever fill the input; nothing from a project runs on its own.
public enum ProjectWorkflows {
    public struct Found: Equatable, Sendable {
        /// The `.rune/workflows.json` file.
        public let file: String
        /// The folder containing `.rune/`.
        public let root: String
        public let workflows: [Workflow]
        public let warnings: [String]
    }

    public static let relativePath = ".rune/workflows.json"

    /// The nearest project workflows file at or above `directory`.
    public static func find(from directory: String, home: String = NSHomeDirectory(),
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        var folder = (directory as NSString).standardizingPath
        while true {
            let candidate = (folder as NSString).appendingPathComponent(relativePath)
            if fileExists(candidate) { return candidate }
            if folder == "/" || folder == home { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    public static func parse(_ data: Data, file: String) -> Found {
        var warnings: [String] = []
        var workflows: [Workflow] = []
        if let json = try? JSONSerialization.jsonObject(with: data) {
            let list = (json as? [String: Any])?["workflows"] ?? json
            workflows = Workflow.parse(list, warnings: &warnings)
        } else {
            warnings.append("\(relativePath) isn't valid JSON")
        }
        let root = ((file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return Found(file: file, root: root, workflows: workflows, warnings: warnings)
    }

    /// Loads the workflows for `directory` (nil when there's no project file). Files over
    /// 512 KB are ignored.
    public static func load(for directory: String, home: String = NSHomeDirectory()) -> Found? {
        guard let file = find(from: directory, home: home),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file),
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) < 512 * 1024,
              let data = FileManager.default.contents(atPath: file)
        else { return nil }
        return parse(data, file: file)
    }
}
