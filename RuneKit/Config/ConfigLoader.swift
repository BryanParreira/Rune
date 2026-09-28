import Foundation

/// Where Rune keeps its files for the current user.
public struct ConfigPaths: Equatable, Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var configFile: URL { directory.appendingPathComponent("config.json") }
    public var themesDirectory: URL { directory.appendingPathComponent("themes", isDirectory: true) }

    /// `$XDG_CONFIG_HOME/rune` if set, otherwise `~/.config/rune`.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ConfigPaths {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty, xdg.hasPrefix("/") {
            return ConfigPaths(directory: URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("rune", isDirectory: true))
        }
        return ConfigPaths(directory: home.appendingPathComponent(".config/rune", isDirectory: true))
    }
}

/// Result of loading config: always usable, plus any problems found along the way.
public struct LoadedConfig: Sendable {
    public var config: RuneConfig
    public var warnings: [String]
    /// Directories searched for themes (and later workflows), highest priority first.
    public var resourceDirectories: [URL]
    /// Directories whose changes should trigger a reload.
    public var watchedDirectories: [URL]
    /// The sync folder in use, if `syncPath` is set and readable.
    public var activeSyncDirectory: URL?
}

/// Loads config with this precedence (later wins):
/// built-in defaults → local config.json (or syncPath/config.json when set) → hosts[<hostname>].
public struct ConfigLoader: Sendable {
    public let paths: ConfigPaths
    public let hostnames: [String]
    public let home: URL

    /// - Parameter hostnames: names this machine answers to, most general first
    ///   (e.g. `["studio", "studio.local"]`). See ``HostIdentity``.
    public init(paths: ConfigPaths, hostnames: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.paths = paths
        self.hostnames = hostnames
        self.home = home
    }

    /// Creates the config directory and a default config.json if none exists.
    /// Returns true if a new file was written.
    @discardableResult
    public func ensureDefaultConfig() throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.themesDirectory, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: paths.configFile.path) else { return false }
        try Data(RuneConfig.defaultFileContents.utf8).write(to: paths.configFile, options: .atomic)
        return true
    }

    public func load() -> LoadedConfig {
        var warnings: [String] = []
        var watched = [paths.directory]
        var resources = [paths.directory]

        var document = Self.readJSONObject(at: paths.configFile, warnings: &warnings) ?? [:]
        var syncDirectory: URL?

        if let rawSync = document["syncPath"] as? String,
           !rawSync.trimmingCharacters(in: .whitespaces).isEmpty {
            let syncDir = resolvePath(rawSync)
            let syncFile = syncDir.appendingPathComponent("config.json")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: syncDir.path, isDirectory: &isDir), isDir.boolValue {
                watched.append(syncDir)
                resources.insert(syncDir, at: 0)
                syncDirectory = syncDir
                if FileManager.default.fileExists(atPath: syncFile.path) {
                    if let synced = Self.readJSONObject(at: syncFile, warnings: &warnings) {
                        // The synced file replaces the local one; only the pointer stays local.
                        var replaced = synced
                        replaced["syncPath"] = document["syncPath"]
                        document = replaced
                    } else {
                        warnings.append("Falling back to local config because the synced config is invalid")
                    }
                }
            } else {
                warnings.append("syncPath \"\(rawSync)\" is not a folder; using local config")
            }
        }

        let merged = Self.applyHostOverrides(document, hostnames: hostnames, warnings: &warnings)
        let config = RuneConfig(dictionary: merged, warnings: &warnings)
        return LoadedConfig(
            config: config,
            warnings: warnings,
            resourceDirectories: resources,
            watchedDirectories: watched,
            activeSyncDirectory: syncDirectory
        )
    }

    /// Expands `~`, and resolves relative paths against the config directory.
    func resolvePath(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true)
        }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed, isDirectory: true) }
        return paths.directory.appendingPathComponent(trimmed, isDirectory: true)
    }

    /// Merges every `hosts` entry whose key matches one of `hostnames` (case-insensitive),
    /// in the order the hostnames are given, and strips the `hosts` table from the result.
    public static func applyHostOverrides(_ document: [String: Any], hostnames: [String], warnings: inout [String]) -> [String: Any] {
        var result = document
        let hosts = result.removeValue(forKey: "hosts")
        guard let hosts, !(hosts is NSNull) else { return result }
        guard let table = hosts as? [String: Any] else {
            warnings.append("hosts should be an object keyed by hostname; ignoring it")
            return result
        }
        for name in hostnames {
            for (key, value) in table where key.caseInsensitiveCompare(name) == .orderedSame {
                guard var override = value as? [String: Any] else {
                    warnings.append("hosts.\(key) should be an object; ignoring it")
                    continue
                }
                override.removeValue(forKey: "hosts")
                override.removeValue(forKey: "syncPath")
                result = deepMerge(result, override)
            }
        }
        return result
    }

    /// Recursively merges `overlay` onto `base`. Nested objects merge; everything else replaces.
    public static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let baseChild = result[key] as? [String: Any], let overlayChild = value as? [String: Any] {
                result[key] = deepMerge(baseChild, overlayChild)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Reads a JSON object from disk. Missing file → nil without warning; invalid → nil with warning.
    static func readJSONObject(at url: URL, warnings: inout [String]) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            warnings.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
            guard let dict = object as? [String: Any] else {
                warnings.append("\(url.lastPathComponent) must contain a JSON object; using defaults")
                return nil
            }
            return dict
        } catch {
            warnings.append("\(url.lastPathComponent) is not valid JSON; using defaults")
            return nil
        }
    }
}
