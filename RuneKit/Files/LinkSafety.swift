import Foundation

/// What ⌘-click may do with a link found in output. Output can come from anywhere (a web
/// page through curl, a remote server, a file), and its links can hide where they point.
public enum LinkSafety {
    public enum Verdict: Equatable, Sendable {
        case open
        /// Opening would run something: show it in Finder instead.
        case revealOnly
        /// An unusual URL scheme (another app's): ask first.
        case confirm
    }

    static let safeSchemes: Set<String> = ["http", "https", "mailto"]

    /// Files that run code or install things when opened.
    static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "scpt", "scptd", "applescript", "workflow", "action",
        "pkg", "mpkg", "dmg", "jar", "shortcut", "webloc", "inetloc", "fileloc", "prefpane", "saver",
        "kext", "mobileconfig", "url", "osax", "plugin", "bundle",
    ]

    public static func verdict(forURL url: URL) -> Verdict {
        safeSchemes.contains(url.scheme?.lowercased() ?? "") ? .open : .confirm
    }

    /// For a file: open documents and folders, but never launch apps, installers or scripts.
    public static func verdict(forFile path: String, isDirectory: Bool, isExecutable: Bool) -> Verdict {
        let ext = (path as NSString).pathExtension.lowercased()
        if runnableExtensions.contains(ext) { return .revealOnly }
        if isDirectory { return .open }
        // An executable without a document extension would run in Terminal when opened.
        if isExecutable, ext.isEmpty || ["sh", "zsh", "bash", "fish", "py", "rb", "pl", "js"].contains(ext) { return .revealOnly }
        return .open
    }
}
