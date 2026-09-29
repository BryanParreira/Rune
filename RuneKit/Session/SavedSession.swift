import Foundation

/// What Rune reopens after a relaunch: windows, their tabs, split layouts and folders.
/// Only paths are stored, never commands or output.
public struct SavedSession: Codable, Equatable, Sendable {
    public var windows: [Window]

    public init(windows: [Window]) {
        self.windows = windows
    }

    public struct Window: Codable, Equatable, Sendable {
        /// `NSStringFromRect` of the window frame.
        public var frame: String?
        public var selectedTab: Int
        public var tabs: [Tab]

        public init(frame: String?, selectedTab: Int, tabs: [Tab]) {
            self.frame = frame
            self.selectedTab = selectedTab
            self.tabs = tabs
        }
    }

    public enum Tab: Codable, Equatable, Sendable {
        case terminal(PaneLayout, style: TabStyle? = nil)
        case file(path: String)
    }

    /// Encodes compactly; `nil` if encoding fails.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) -> SavedSession? {
        try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    /// Drops what can't be reopened: missing files, and folders that no longer exist become
    /// the home folder. Windows left without tabs are removed.
    public func validated(fileExists: (String) -> Bool, home: String) -> SavedSession {
        var result = self
        result.windows = windows.compactMap { window in
            var window = window
            window.tabs = window.tabs.compactMap { tab in
                switch tab {
                case .terminal(let layout, let style): return .terminal(layout.replacingMissingDirectories(fileExists: fileExists, home: home), style: style)
                case .file(let path): return fileExists(path) ? tab : nil
                }
            }
            guard !window.tabs.isEmpty else { return nil }
            window.selectedTab = min(max(0, window.selectedTab), window.tabs.count - 1)
            return window
        }
        return result
    }
}

/// A name and color the user gave a tab (either may be unset: the tab then shows the
/// running program or folder, without a color).
public struct TabStyle: Codable, Equatable, Sendable {
    public var title: String?
    public var color: TabColor?

    public init(title: String? = nil, color: TabColor? = nil) {
        self.title = title
        self.color = color
    }

    public var isEmpty: Bool { title == nil && color == nil }
}

public enum TabColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink

    public var displayName: String { rawValue.capitalized }
}

/// Split panes as a tree: a pane is a shell in a folder, a split holds panes side by side
/// (`vertical`) or stacked.
public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case pane(directory: String)
    case split(vertical: Bool, children: [PaneLayout])

    public var paneCount: Int {
        switch self {
        case .pane: return 1
        case .split(_, let children): return children.reduce(0) { $0 + $1.paneCount }
        }
    }

    func replacingMissingDirectories(fileExists: (String) -> Bool, home: String) -> PaneLayout {
        switch self {
        case .pane(let directory):
            return .pane(directory: fileExists(directory) ? directory : home)
        case .split(let vertical, let children):
            let kept = children.map { $0.replacingMissingDirectories(fileExists: fileExists, home: home) }
            return kept.count == 1 ? kept[0] : .split(vertical: vertical, children: kept)
        }
    }
}
