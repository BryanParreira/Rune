import Foundation
import RuneKit

/// ~/Library/Application Support/Rune/session.json: the windows to reopen at launch.
/// Per Mac and never synced; it holds folder and file paths only.
enum SessionFile {
    #if DEBUG
    /// Test runs point this at a scratch file (they never touch the real one).
    static var testOverride: URL? {
        ProcessInfo.processInfo.environment["RUNE_DEBUG_SESSION_FILE"].map { URL(fileURLWithPath: $0) }
    }
    #endif

    static var url: URL? {
        #if DEBUG
        if let testOverride { return testOverride }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Rune", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    static func load() -> SavedSession? {
        guard let url, let data = try? Data(contentsOf: url), let saved = SavedSession.decode(data) else { return nil }
        let valid = saved.validated(fileExists: { FileManager.default.fileExists(atPath: $0) }, home: NSHomeDirectory())
        return valid.windows.isEmpty ? nil : valid
    }

    static func save(_ session: SavedSession) {
        guard let url, let data = session.encoded() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
