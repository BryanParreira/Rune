import AppKit
import RuneKit

/// Help › Report a Problem: collects what helps diagnose an issue into a folder the user can
/// read before sharing it. Nothing is sent anywhere; secrets are removed from the settings.
enum ProblemReport {
    static let issuesURL = "https://github.com/BryanParreira/Rune/issues/new"

    /// Writes the report folder and returns it (in Application Support, which needs no
    /// permission prompt).
    static func create(sessions: [TerminalSession], config: ConfigStore) -> URL? {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let folder = support.appendingPathComponent("Rune/Problem Reports/Report \(stamp)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try summary(sessions: sessions, config: config).write(to: folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
            // Settings, without anything that looks like a credential.
            if let text = try? String(contentsOf: config.writableConfigFile, encoding: .utf8) {
                try SecretRedactor.redact(text).write(to: folder.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
            }
            for crash in recentCrashReports(limit: 3) {
                try? fileManager.copyItem(at: crash, to: folder.appendingPathComponent(crash.lastPathComponent))
            }
            return folder
        } catch {
            return nil
        }
    }

    /// What's in report.md: versions, the Mac, every open shell and its state, config warnings.
    static func summary(sessions: [TerminalSession], config: ConfigStore? = nil) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "Apple silicon"
        #else
        let arch = "Intel"
        #endif
        var lines = [
            "# Rune problem report",
            "",
            "- Rune \(version) (\(build))",
            "- macOS \(os), \(arch)",
            "- Open shells: \(sessions.count)",
        ]
        for (index, session) in sessions.enumerated() {
            lines.append("  - \(index + 1). \((session.shellExecutable as NSString).lastPathComponent): integration \(session.integration), \(session.mode), \(session.state)")
        }
        if let config {
            let settings = config.snapshot.config
            lines += [
                "- Theme \(settings.theme), font \(settings.fontFamily) \(Int(settings.fontSize)), input \(settings.inputMode.rawValue)",
                "- GPU rendering \(settings.gpuRendering ? "on" : "off"), honor prompt \(settings.honorPrompt ? "on" : "off")",
            ]
            if !config.snapshot.warnings.isEmpty {
                lines += ["", "## Settings warnings", ""] + config.snapshot.warnings.map { "- " + $0 }
            }
        }
        let crashes = recentCrashReports(limit: 3)
        lines += ["", "## Recent crash reports", ""]
        lines += crashes.isEmpty ? ["None in the last 30 days."] : crashes.map { "- " + $0.lastPathComponent }
        lines += ["", "## What happened", "", "(Describe what you did and what you expected.)", ""]
        return lines.joined(separator: "\n")
    }

    /// Crash reports macOS kept for Rune, newest first (only from the last 30 days).
    static func recentCrashReports(limit: Int) -> [URL] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("Rune") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > cutoff else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// A new GitHub issue with the summary filled in (the user attaches the folder).
    static func issueURL(summary: String) -> URL? {
        var components = URLComponents(string: issuesURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Problem: "),
            URLQueryItem(name: "body", value: summary + "\n_(Attach files from the report folder if they help.)_"),
        ]
        return components?.url
    }
}
