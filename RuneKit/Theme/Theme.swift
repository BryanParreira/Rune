import Foundation

/// 8-bit sRGB color parsed from "#rgb" / "#rrggbb".
public struct RGB: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

/// Terminal color scheme.
public struct Theme: Equatable, Sendable {
    public var name: String
    public var background: RGB
    public var foreground: RGB
    public var cursor: RGB
    public var selectionBackground: RGB
    public var selectionForeground: RGB
    /// UI accent (focus rings, selected block, editor caret).
    public var accent: RGB
    /// 16 ANSI colors: 0–7 normal, 8–15 bright.
    public var ansi: [RGB]

    /// Rune's built-in dark theme.
    public static let runeDark = Theme(
        name: "rune-dark",
        background: RGB(0x0A, 0x0A, 0x0A),
        foreground: RGB(0xE4, 0xE4, 0xE4),
        cursor: RGB(0xF2, 0xF2, 0xF2),
        // rgb(118,167,250) at 40% over the background.
        selectionBackground: RGB(0x35, 0x49, 0x6A),
        selectionForeground: RGB(0xF2, 0xF2, 0xF2),
        accent: RGB(0x5B, 0x9C, 0xFF),
        ansi: [
            "#1c1c1c", "#ff5f59", "#5fd787", "#f0c674", "#6ea8fe", "#c792ea", "#56d4dd", "#cfcfcf",
            "#4d4d4d", "#ff7b72", "#7ee2a0", "#ffd787", "#8fbcff", "#d8a8ff", "#7ee8f0", "#ffffff",
        ].compactMap(RGB.init(hex:))
    )

    /// Default: warm beige paper, softer than white, with ink text, amber accents and a
    /// yellow highlighter for selections. ANSI colors are deepened to read on a light page.
    public static let paper = Theme(
        name: "paper",
        background: RGB(0xEE, 0xE7, 0xDA),
        foreground: RGB(0x2A, 0x28, 0x22),
        cursor: RGB(0x2A, 0x28, 0x22),
        // Highlighter yellow (#facc15) at ~35% over the paper.
        selectionBackground: RGB(0xF2, 0xDE, 0x95),
        selectionForeground: RGB(0x2A, 0x28, 0x22),
        accent: RGB(0xB4, 0x53, 0x09),
        ansi: [
            "#2a2822", "#b3261e", "#34702f", "#855a00", "#2f5d9e", "#8a3f8f", "#17706f", "#857f73",
            "#6b6760", "#d0342c", "#4f9148", "#b8860b", "#3a6fc4", "#a64fa6", "#2a9090", "#3a3830",
        ].compactMap(RGB.init(hex:))
    )

    /// Warm dark: the same paper feel at night.
    public static let paperNight = Theme(
        name: "paper-night",
        background: RGB(0x12, 0x11, 0x0E),
        foreground: RGB(0xF0, 0xED, 0xE8),
        cursor: RGB(0xF5, 0xB8, 0x3D),
        // Highlighter yellow at ~25% over the page.
        selectionBackground: RGB(0x4C, 0x40, 0x10),
        selectionForeground: RGB(0xF7, 0xF4, 0xEE),
        accent: RGB(0xF5, 0xB8, 0x3D),
        ansi: [
            "#2a2825", "#f2766b", "#9ccc7a", "#f5c451", "#86a8e8", "#d49ae0", "#7fcfc4", "#d8d3c8",
            "#6b665c", "#ff8e82", "#b4dd93", "#ffd66e", "#a3bff0", "#e3b3ec", "#9fe0d6", "#f7f4ee",
        ].compactMap(RGB.init(hex:))
    )

    public static let builtIn: [String: Theme] = [
        paper.name: paper, paperNight.name: paperNight, runeDark.name: runeDark,
    ]

    /// Relative luminance of the background (0 = black, 1 = white).
    public var backgroundLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(background.r) + 0.7152 * channel(background.g) + 0.0722 * channel(background.b)
    }

    public var isLight: Bool { backgroundLuminance > 0.4 }

    /// Name shown in Settings.
    public static func displayName(_ name: String) -> String {
        switch name {
        case "paper": return "Paper (light)"
        case "paper-night": return "Paper Night (dark)"
        case "rune-dark": return "Rune Classic (dark)"
        default: return name
        }
    }
}

extension Theme {
    /// Applies a user theme JSON object on top of `base`. Unknown/invalid fields warn and are skipped.
    public init(overlay dict: [String: Any], name: String, base: Theme, warnings: inout [String]) {
        self = base
        self.name = name

        func color(_ key: String) -> RGB? {
            guard let raw = dict[key] else { return nil }
            guard let s = raw as? String, let rgb = RGB(hex: s) else {
                warnings.append("Theme \(name): \(key) should be a hex color like \"#1e1e1e\"")
                return nil
            }
            return rgb
        }

        if let c = color("background") { background = c }
        if let c = color("foreground") { foreground = c }
        if let c = color("cursor") { cursor = c }
        if let c = color("selectionBackground") { selectionBackground = c }
        if let c = color("selectionForeground") { selectionForeground = c }
        if let c = color("accent") { accent = c }
        if let raw = dict["ansi"] {
            let parsed = (raw as? [String])?.compactMap(RGB.init(hex:)) ?? []
            if parsed.count == 16 {
                ansi = parsed
            } else {
                warnings.append("Theme \(name): ansi should be a list of 16 hex colors")
            }
        }
    }
}

/// Resolves a theme name to a `Theme`, looking in `<dir>/themes/<name>.json` for each
/// resource directory before falling back to the built-ins.
public enum ThemeLoader {
    public static func load(named name: String, resourceDirectories: [URL], warnings: inout [String]) -> Theme {
        let fm = FileManager.default
        for dir in resourceDirectories {
            let file = dir.appendingPathComponent("themes", isDirectory: true).appendingPathComponent("\(name).json")
            guard fm.fileExists(atPath: file.path) else { continue }
            guard let dict = ConfigLoader.readJSONObject(at: file, warnings: &warnings) else {
                return Theme.builtIn[name] ?? .paper
            }
            // A user theme may "extend" a built-in; otherwise it layers on rune-dark.
            let baseName = dict["extends"] as? String
            let base = baseName.flatMap { Theme.builtIn[$0] } ?? Theme.builtIn[name] ?? .paper
            return Theme(overlay: dict, name: name, base: base, warnings: &warnings)
        }
        if let builtIn = Theme.builtIn[name] { return builtIn }
        warnings.append("Theme \"\(name)\" not found; using rune-dark")
        return .paper
    }
}
