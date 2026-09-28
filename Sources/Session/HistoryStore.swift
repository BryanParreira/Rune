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
