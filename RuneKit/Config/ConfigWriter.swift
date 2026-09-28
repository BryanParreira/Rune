import Foundation

/// Updates individual settings in a config.json file (used by the Settings window).
/// The file stays the single source of truth; the watcher picks up the change.
public struct ConfigWriter: Sendable {
    public enum Scope: Equatable, Sendable {
        /// Top-level setting shared by every machine that reads this file.
        case allMachines
        /// `hosts[<name>]` override for one machine.
        case host(String)
    }

    public enum WriteError: Error, LocalizedError {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason): return reason
            }
        }
    }

    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The file settings should be written to: the synced config when a sync folder is active.
    public static func target(for loaded: LoadedConfig, paths: ConfigPaths) -> URL {
        if let sync = loaded.activeSyncDirectory {
            return sync.appendingPathComponent("config.json")
        }
        return paths.configFile
    }

    /// Sets `key` to `value` (nil removes the key) and rewrites the file.
    /// Refuses to overwrite a file that exists but can't be parsed, so nothing is lost.
    public func set(_ key: String, to value: Any?, scope: Scope = .allMachines) throws {
        var document = try readDocument()
        switch scope {
        case .allMachines:
            document[key] = value
        case .host(let name):
            var hosts = document["hosts"] as? [String: Any] ?? [:]
            // Reuse an existing entry that matches case-insensitively.
            let hostKey = hosts.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            var entry = hosts[hostKey] as? [String: Any] ?? [:]
            entry[key] = value
            hosts[hostKey] = entry.isEmpty ? nil : entry
            document["hosts"] = hosts
        }
        try write(document)
    }

    /// Current value of `key` in the file for the given scope (not merged with defaults).
    public func value(_ key: String, scope: Scope = .allMachines) -> Any? {
        guard let document = try? readDocument() else { return nil }
        switch scope {
        case .allMachines:
            return document[key]
        case .host(let name):
            let hosts = document["hosts"] as? [String: Any] ?? [:]
            let entry = hosts.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            return (entry as? [String: Any])?[key]
        }
    }

    func readDocument() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]),
              let dict = object as? [String: Any]
        else {
            throw WriteError.unreadable("\(file.lastPathComponent) has a syntax error. Fix it in a text editor before changing settings here.")
        }
        return dict
    }

    func write(_ document: [String: Any]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: file, options: .atomic)
    }
}
