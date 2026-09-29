import Foundation
import RuneKit

extension CommandCatalog {
    /// Command names known to the app, shared by every tab. Seeded from the app's own PATH;
    /// replaced with the shell's real PATH once the integration reports it.
    static let shared: CommandCatalog = {
        let catalog = CommandCatalog()
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        DispatchQueue.global(qos: .utility).async {
            catalog.loadExecutables(path: path, onlyIfEmpty: true)
        }
        return catalog
    }()
}

/// Command history shared by every tab: the user's zsh history plus commands run in Rune.
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var history = CommandHistory()
    private var loaded = false

    private init() {}

    /// Loads ~/.zsh_history (or $HISTFILE) once, off the main thread.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = CommandHistory.zshHistoryURL(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? Data(contentsOf: url) else { return }
            let entries = CommandHistory.parseZshHistory(data)
            DispatchQueue.main.async {
                // Anything run in Rune before the file finished loading stays newest.
                let sessionEntries = self.history.entries
                var merged = CommandHistory(entries: entries)
                sessionEntries.forEach { merged.append($0) }
                self.history = merged
            }
        }
    }

    func append(_ command: String) {
        history.append(command)
    }
}

/// Folders recently visited in any Rune pane, newest first (for the command palette).
/// Stored per Mac in user defaults; paths only, never commands or output.
final class RecentDirectories {
    static let shared = RecentDirectories()
    private static let key = "RuneRecentDirectories"
    private static let limit = 40

    private(set) var paths: [String]

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func record(_ path: String) {
        guard !path.isEmpty else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
        UserDefaults.standard.set(paths, forKey: Self.key)
    }
}
