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

/// Loads config on launch, creates a default file if needed, republishes on file changes, and
/// writes individual settings back for the Settings window.
final class ConfigStore {
    /// The app's store (set by AppDelegate), for views that write settings.
    static weak var current: ConfigStore?

    let paths: ConfigPaths
    private let loader: ConfigLoader
    private var watcher: DirectoryWatcher?
    private var appearanceObservation: NSKeyValueObservation?

    /// macOS is in Dark Mode (Rune's windows set their own appearance; the app's follows the system).
    static var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    private(set) var loaded: LoadedConfig

    @Published private(set) var snapshot: ConfigSnapshot
    /// Set when writing a setting fails; shown in the Settings window.
    @Published private(set) var lastWriteError: String?

    init(paths: ConfigPaths = .standard()) {
        self.paths = paths
        self.loader = ConfigLoader(paths: paths, hostnames: HostIdentity.configMatchNames())

        var setupWarnings: [String] = []
        do {
            try loader.ensureDefaultConfig()
        } catch {
            setupWarnings.append("Could not create \(paths.configFile.path): \(error.localizedDescription)")
        }
        let (loaded, snapshot, watched) = Self.load(loader)
        self.loaded = loaded
        var initial = snapshot
        initial.warnings.insert(contentsOf: setupWarnings, at: 0)
        self.snapshot = initial

        let watcher = DirectoryWatcher { [weak self] in self?.reload() }
        watcher.watch(watched)
        self.watcher = watcher
        // macOS switching between Light and Dark Mode (for "Match system appearance").
        appearanceObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func reload() {
        let (loaded, next, watched) = Self.load(loader)
        self.loaded = loaded
        if !next.warnings.isEmpty, next.warnings != snapshot.warnings {
            Log.config.notice("Settings loaded with \(next.warnings.count) warning(s)")
        }
        watcher?.watch(watched)
        if next != snapshot {
            snapshot = next
        }
    }

    /// The machine name used for `hosts` overrides.
    var hostName: String {
        HostIdentity.configMatchNames().last ?? HostIdentity.displayHostname()
    }

    /// File that settings are written to (the synced config when a sync folder is active).
    var writableConfigFile: URL {
        ConfigWriter.target(for: loaded, paths: paths)
    }

    /// Writes one setting and reloads immediately (the file watcher would also catch it).
    func write(key: String, value: Any?, thisMachineOnly: Bool = false) {
        let writer = ConfigWriter(file: writableConfigFile)
        do {
            try writer.set(key, to: value, scope: thisMachineOnly ? .host(hostName) : .allMachines)
            lastWriteError = nil
            reload()
        } catch {
            Log.config.error("Couldn't write setting \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastWriteError = error.localizedDescription
        }
    }

    /// Removes a per-machine override so the shared value applies again.
    func clearMachineOverride(key: String) {
        write(key: key, value: nil, thisMachineOnly: true)
    }

    func hasMachineOverride(key: String) -> Bool {
        ConfigWriter(file: writableConfigFile).value(key, scope: .host(hostName)) != nil
    }

    /// Built-in themes plus any `themes/*.json` in the config or sync folder.
    func availableThemes() -> [String] {
        var names = Set(Theme.builtIn.keys)
        for dir in loaded.resourceDirectories {
            let themes = dir.appendingPathComponent("themes", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: themes.path)) ?? []
            for file in files where file.hasSuffix(".json") {
                names.insert(String(file.dropLast(5)))
            }
        }
        return names.sorted()
    }

    private static func load(_ loader: ConfigLoader) -> (LoadedConfig, ConfigSnapshot, [URL]) {
        let loaded = loader.load()
        var warnings = loaded.warnings
        let config = loaded.config
        SecretRedactor.setCustomPatterns(config.secretPatterns)
        var theme = ThemeLoader.load(named: config.themeName(systemIsDark: systemIsDark), resourceDirectories: loaded.resourceDirectories, warnings: &warnings)
        if config.minimumContrast { theme = theme.withMinimumContrast() }
        let font = FontResolver.font(family: config.fontFamily, size: config.fontSize, weight: config.fontWeight, warnings: &warnings)
        let themeDirs = loaded.resourceDirectories.map { $0.appendingPathComponent("themes", isDirectory: true) }
        let snapshot = ConfigSnapshot(config: loaded.config, theme: theme, font: font, warnings: warnings)
        return (loaded, snapshot, loaded.watchedDirectories + themeDirs)
    }
}

enum FontResolver {
    /// Names that mean "the system monospaced font" (SF Mono on current macOS).
    private static let systemAliases: Set<String> = ["sf mono", "sfmono", "system", "monospace", "ui-monospace"]

    static func font(family: String, size: Double, weight: String = "regular", warnings: inout [String]) -> NSFont {
        withIconFallback(baseFont(family: family, size: size, weight: weight, warnings: &warnings))
    }

    /// NSFontManager weights (0–15, 5 = regular) and system font weights for each setting.
    private static func weights(_ name: String) -> (manager: Int, system: NSFont.Weight) {
        switch name {
        case "light": return (3, .light)
        case "medium": return (6, .medium)
        case "semibold": return (8, .semibold)
        case "bold": return (9, .bold)
        default: return (5, .regular)
        }
    }

    private static func baseFont(family: String, size: Double, weight: String, warnings: inout [String]) -> NSFont {
        let pointSize = CGFloat(size)
        let (managerWeight, systemWeight) = weights(weight)
        let system = NSFont.monospacedSystemFont(ofSize: pointSize, weight: systemWeight)
        let trimmed = family.trimmingCharacters(in: .whitespaces)

        // The requested weight when the family has it, otherwise its regular face.
        if let byFamily = NSFontManager.shared.font(withFamily: trimmed, traits: [], weight: managerWeight, size: pointSize)
            ?? NSFontManager.shared.font(withFamily: trimmed, traits: [], weight: 5, size: pointSize) {
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

    /// An installed Nerd Font to borrow icon glyphs from, preferring symbol-only and Mono variants.
    static let iconFallbackFamily: String? = {
        let families = NSFontManager.shared.availableFontFamilies.filter { $0.localizedCaseInsensitiveContains("Nerd Font") }
        let ranked = families.sorted { rank($0) < rank($1) }
        return ranked.first
    }()

    private static func rank(_ family: String) -> Int {
        if family.hasPrefix("Symbols Nerd Font Mono") { return 0 }
        if family.hasPrefix("Symbols Nerd Font") { return 1 }
        if family.hasSuffix("Nerd Font Mono") { return 2 }
        return 3
    }

    /// Adds an installed Nerd Font to the font's cascade list so Powerline/devicon glyphs
    /// render even when the main font lacks them. No-op if the font already is a Nerd Font.
    static func withIconFallback(_ font: NSFont) -> NSFont {
        guard let familyName = font.familyName, !familyName.localizedCaseInsensitiveContains("Nerd Font"),
              let fallback = iconFallbackFamily,
              let fallbackFont = NSFontManager.shared.font(withFamily: fallback, traits: [], weight: 5, size: font.pointSize)
        else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [fallbackFont.fontDescriptor]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Installed fixed-pitch font families, for the Settings picker.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { family in
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 13) else { return false }
            return font.isFixedPitch || manager.traits(of: font).contains(.fixedPitchFontMask)
        }
        return (["JetBrains Mono", "SF Mono"] + families.filter { $0 != "SF Mono" && $0 != "JetBrains Mono" }).removingDuplicates()
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
