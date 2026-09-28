import AppKit
import Combine
import RuneKit

/// Everything the UI needs from config, resolved and ready to apply.
struct ConfigSnapshot: Equatable {
    var config: RuneConfig
    var theme: Theme
    var font: NSFont
    var warnings: [String]
}

/// Loads config on launch, creates a default file if needed, and republishes on file changes.
final class ConfigStore {
    let paths: ConfigPaths
    private let loader: ConfigLoader
    private var watcher: DirectoryWatcher?

    @Published private(set) var snapshot: ConfigSnapshot

    init(paths: ConfigPaths = .standard()) {
        self.paths = paths
        self.loader = ConfigLoader(paths: paths, hostnames: HostIdentity.configMatchNames())

        var setupWarnings: [String] = []
        do {
            try loader.ensureDefaultConfig()
        } catch {
            setupWarnings.append("Could not create \(paths.configFile.path): \(error.localizedDescription)")
        }
        let (snapshot, watched) = Self.makeSnapshot(loader: loader)
        var initial = snapshot
        initial.warnings.insert(contentsOf: setupWarnings, at: 0)
        self.snapshot = initial

        let watcher = DirectoryWatcher { [weak self] in self?.reload() }
        watcher.watch(watched)
        self.watcher = watcher
    }

    func reload() {
        let (next, watched) = Self.makeSnapshot(loader: loader)
        watcher?.watch(watched)
        if next != snapshot {
            snapshot = next
        }
    }

    private static func makeSnapshot(loader: ConfigLoader) -> (ConfigSnapshot, [URL]) {
        let loaded = loader.load()
        var warnings = loaded.warnings
        let theme = ThemeLoader.load(named: loaded.config.theme, resourceDirectories: loaded.resourceDirectories, warnings: &warnings)
        let font = FontResolver.font(family: loaded.config.fontFamily, size: loaded.config.fontSize, warnings: &warnings)
        let themeDirs = loaded.resourceDirectories.map { $0.appendingPathComponent("themes", isDirectory: true) }
        let snapshot = ConfigSnapshot(config: loaded.config, theme: theme, font: font, warnings: warnings)
        return (snapshot, loaded.watchedDirectories + themeDirs)
    }
}

enum FontResolver {
    /// Names that mean "the system monospaced font" (SF Mono on current macOS).
    private static let systemAliases: Set<String> = ["sf mono", "sfmono", "system", "monospace", "ui-monospace"]

    static func font(family: String, size: Double, warnings: inout [String]) -> NSFont {
        let pointSize = CGFloat(size)
        let system = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let trimmed = family.trimmingCharacters(in: .whitespaces)

        if let byFamily = NSFontManager.shared.font(withFamily: trimmed, traits: [], weight: 5, size: pointSize) {
            return byFamily
        }
        if let byName = NSFont(name: trimmed, size: pointSize) {
            return byName
        }
        if systemAliases.contains(trimmed.lowercased()) {
            return system
        }
        warnings.append("Font \"\(trimmed)\" is not installed; using the system monospaced font")
        return system
    }
}
