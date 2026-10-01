import Foundation

/// A keyboard shortcut written as text in config.json: `"cmd+shift+]"`, `"ctrl+option+t"`,
/// `"cmd+up"`, or `"none"` to remove one.
public struct ShortcutSpec: Equatable, Sendable {
    /// A single character (lowercased), or a key name: up, down, left, right, return, tab,
    /// space, delete, escape, f1…f20.
    public var key: String
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public static let namedKeys: Set<String> = ["up", "down", "left", "right", "return", "tab", "space", "delete", "escape"]

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Nil for text that isn't a shortcut (and for "none").
    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // "cmd++" means the + key.
        var tokens = parts
        if text.hasSuffix("++") { tokens = Array(parts.dropLast(2)) + ["+"] }
        guard let last = tokens.last, !last.isEmpty, last != "none" else { return nil }
        key = last
        for modifier in tokens.dropLast() {
            switch modifier {
            case "cmd", "command", "⌘": command = true
            case "shift", "⇧": shift = true
            case "opt", "option", "alt", "⌥": option = true
            case "ctrl", "control", "⌃": control = true
            default: return nil
            }
        }
        let isFunctionKey = key.hasPrefix("f") && Int(key.dropFirst()).map { (1...20).contains($0) } == true
        guard key.count == 1 || Self.namedKeys.contains(key) || isFunctionKey else { return nil }
        // A shortcut needs a modifier, except function keys.
        guard command || control || option || isFunctionKey else { return nil }
    }

    /// The text form, modifiers in a fixed order: `ctrl+option+shift+cmd+k`.
    public var text: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("option") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// How menus show it: ⌃⌥⇧⌘K.
    public var display: String {
        let names: [String: String] = ["up": "↑", "down": "↓", "left": "←", "right": "→", "return": "↵", "tab": "⇥",
                                       "space": "Space", "delete": "⌫", "escape": "esc"]
        let symbol = names[key] ?? key.uppercased()
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + symbol
    }
}
