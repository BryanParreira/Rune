import Foundation

/// Node's version for the context chip, shown only inside a Node project (a folder with a
/// package.json, here or above). `node --version` runs once per node binary and is cached.
public enum NodeVersion {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    /// Call off the main thread.
    public static func forProject(at path: String, searchPath: String) -> String? {
        guard isNodeProject(path) else { return nil }
        let fm = FileManager.default
        guard let node = searchPath.split(separator: ":").map({ String($0) + "/node" }).first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let resolved = (try? fm.destinationOfSymbolicLink(atPath: node)).map { ($0 as NSString).isAbsolutePath ? $0 : ((node as NSString).deletingLastPathComponent as NSString).appendingPathComponent($0) } ?? node
        lock.lock()
        if let cached = cache[resolved] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, version.hasPrefix("v"), version.count < 24 else { return nil }
        let short = String(version.dropFirst())
        lock.lock()
        cache[resolved] = short
        lock.unlock()
        return short
    }

    /// A package.json in `path` or up to six folders above it (not above the home folder).
    static func isNodeProject(_ path: String) -> Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var folder = path
        for _ in 0..<7 {
            if fm.fileExists(atPath: folder + "/package.json") { return true }
            if folder == home || folder == "/" { return false }
            folder = (folder as NSString).deletingLastPathComponent
            if folder.isEmpty { return false }
        }
        return false
    }
}
