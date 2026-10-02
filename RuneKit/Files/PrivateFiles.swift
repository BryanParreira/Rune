import Foundation

/// Rune's own records (Recall, the saved session, problem reports) are readable only by the
/// user who owns them: other accounts on the Mac can't list or open them.
public enum PrivateFiles {
    /// Owner-only: a folder becomes 0700, a file 0600. Missing paths are ignored.
    public static func restrict(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        chmod(url.path, isDirectory.boolValue ? 0o700 : 0o600)
    }

    /// Creates the folder (owner-only) if needed.
    public static func makeDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        restrict(url)
    }
}
