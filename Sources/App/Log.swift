import Foundation
import os

/// Rune's diagnostics in the macOS unified log (Console.app, `log show`), on this Mac only.
/// Paths, commands and other user text are logged as private (redacted unless the Mac allows
/// private data), so a Problem Report carries what happened, not what you were working on.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "dev.rune.Rune"

    /// Launch, quit, windows, updates.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Shells: start, exit, integration.
    static let session = Logger(subsystem: subsystem, category: "session")
    /// Settings files: loading, writing.
    static let config = Logger(subsystem: subsystem, category: "config")

    /// Recent entries, for a Problem Report. Runs `log show` (a second or two).
    static func recentEntries(lastMinutes: Int = 60) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--style", "compact", "--last", "\(lastMinutes)m",
                             "--predicate", "subsystem == \"\(subsystem)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Process-wide limits a terminal needs.
enum ProcessLimits {
    /// Apps started from the Dock get a soft limit of 256 open files, and every shell, tool
    /// and file watcher started in Rune inherits it ("too many open files" in node, webpack,
    /// language servers…). Raise the soft limit as far as the system allows (Warp does too).
    static func raiseOpenFileLimit(to target: rlim_t = 10_240) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let desired = min(target, limit.rlim_max)
        guard limit.rlim_cur < desired else { return }
        let before = limit.rlim_cur
        limit.rlim_cur = desired
        if setrlimit(RLIMIT_NOFILE, &limit) == 0 {
            Log.app.notice("Open file limit raised from \(before) to \(desired)")
        } else {
            Log.app.error("Couldn't raise the open file limit (errno \(errno))")
        }
    }

    /// An Objective-C exception about to end the app is written to the log first.
    static func logUncaughtExceptions() {
        NSSetUncaughtExceptionHandler { exception in
            Log.app.fault("Uncaught exception \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "", privacy: .public)\n\(exception.callStackSymbols.prefix(20).joined(separator: "\n"), privacy: .public)")
        }
    }
}
