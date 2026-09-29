import Foundation

/// A saved window setup the user can open again: tabs with their names, colors, split panes,
/// folders, and optionally a command each pane starts with (a dev server, a log tail…).
/// Stored as small JSON files in `~/.config/rune/layouts/`, meant to be read and edited by hand:
///
///     {
///       "name": "Web app",
///       "tabs": [
///         { "title": "api", "color": "green", "split": "right", "panes": [
///             { "directory": "~/code/api", "command": "npm run dev" },
///             { "directory": "~/code/api" } ] },
///         { "directory": "~/code/web" }
///       ]
///     }
public struct LaunchLayout: Codable, Equatable, Sendable {
    public var name: String
    public var tabs: [Tab]

    public init(name: String, tabs: [Tab]) {
        self.name = name
        self.tabs = tabs
    }

    public struct Tab: Codable, Equatable, Sendable {
        public var title: String?
        public var color: TabColor?
        public var root: Pane

        public init(title: String? = nil, color: TabColor? = nil, root: Pane) {
            self.title = title
            self.color = color
            self.root = root
        }

        private enum CodingKeys: String, CodingKey { case title, color }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            // An unknown color name shouldn't make the whole layout unusable.
            color = (try? container.decodeIfPresent(String.self, forKey: .color)).flatMap { $0.flatMap(TabColor.init(rawValue:)) }
            root = try Pane(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(color, forKey: .color)
            try root.encode(to: encoder)
        }

        public var style: TabStyle? {
            let style = TabStyle(title: title, color: color)
            return style.isEmpty ? nil : style
        }
    }

    /// A shell in a folder, or panes side by side ("split": "right") or stacked ("down").
    public indirect enum Pane: Codable, Equatable, Sendable {
        case shell(directory: String, command: String?)
        case split(vertical: Bool, panes: [Pane])

        private enum CodingKeys: String, CodingKey { case directory, command, split, panes }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let panes = try container.decodeIfPresent([Pane].self, forKey: .panes) {
                guard !panes.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .panes, in: container, debugDescription: "“panes” is empty")
                }
                let direction = try container.decodeIfPresent(String.self, forKey: .split) ?? "right"
                self = panes.count == 1 ? panes[0] : .split(vertical: direction != "down", panes: panes)
            } else {
                let command = try container.decodeIfPresent(String.self, forKey: .command)
                self = .shell(directory: try container.decodeIfPresent(String.self, forKey: .directory) ?? "~",
                              command: command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? command : nil)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .shell(let directory, let command):
                try container.encode(directory, forKey: .directory)
                try container.encodeIfPresent(command, forKey: .command)
            case .split(let vertical, let panes):
                try container.encode(vertical ? "right" : "down", forKey: .split)
                try container.encode(panes, forKey: .panes)
            }
        }

        /// Builds a pane tree from a window's layout and the command of each pane, in layout
        /// order. Folders under `home` are written with `~` so the file works on other Macs.
        public init(layout: PaneLayout, commands: [String?], home: String) {
            var remaining = commands[...]
            func build(_ node: PaneLayout) -> Pane {
                switch node {
                case .pane(let directory):
                    let command = remaining.popFirst() ?? nil
                    return .shell(directory: LaunchLayout.abbreviate(directory, home: home), command: command)
                case .split(let vertical, let children):
                    return .split(vertical: vertical, panes: children.map(build))
                }
            }
            self = build(layout)
        }

        /// The pane tree Rune opens, with `~` expanded and missing folders replaced by `home`.
        public func layout(home: String, fileExists: (String) -> Bool) -> PaneLayout {
            switch self {
            case .shell(let directory, _):
                let expanded = LaunchLayout.expand(directory, home: home)
                return .pane(directory: fileExists(expanded) ? expanded : home)
            case .split(let vertical, let panes):
                return .split(vertical: vertical, children: panes.map { $0.layout(home: home, fileExists: fileExists) })
            }
        }

        /// Each pane's start command, in the same order as the panes of `layout`.
        public var commands: [String?] {
            switch self {
            case .shell(_, let command): return [command]
            case .split(_, let panes): return panes.flatMap(\.commands)
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case name, tabs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        tabs = try container.decode([Tab].self, forKey: .tabs)
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// Reads and writes the layout files.
public struct LaunchLayoutStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(paths: ConfigPaths) {
        self.init(directory: paths.directory.appendingPathComponent("layouts", isDirectory: true))
    }

    /// Every readable layout, by name. A file without a name uses its file name.
    public func loadAll() -> [(layout: LaunchLayout, file: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), var layout = try? JSONDecoder().decode(LaunchLayout.self, from: data),
                  !layout.tabs.isEmpty else { return nil }
            if layout.name.trimmingCharacters(in: .whitespaces).isEmpty { layout.name = file.deletingPathExtension().lastPathComponent }
            return (layout, file)
        }
        .sorted { $0.layout.name.localizedStandardCompare($1.layout.name) == .orderedAscending }
    }

    /// Writes `layout` to `<name>.json`, replacing a layout with the same file name.
    @discardableResult
    public func save(_ layout: LaunchLayout) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let file = directory.appendingPathComponent(Self.fileName(for: layout.name))
        try encoder.encode(layout).write(to: file, options: .atomic)
        return file
    }

    public func fileExists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.fileName(for: name)).path)
    }

    /// "Web App: dev" → "web-app-dev.json".
    public static func fileName(for name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return (slug.isEmpty ? "layout" : slug) + ".json"
    }
}
