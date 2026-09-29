import Foundation

/// Cursor shape as written in config.json.
public enum CursorShape: String, CaseIterable, Sendable {
    case bar
    case block
    case underline
}

/// Where commands are typed.
public enum InputStyle: String, CaseIterable, Sendable {
    /// Rune's own editor pinned to the bottom (history suggestions, highlighting, completion).
    case editor
    /// Directly at the shell prompt, so every zsh line-editor plugin works as usual.
    case shell
}

/// Fully resolved Rune settings. Every field has a default, so a missing or
/// partially invalid config file still produces a usable value.
public struct RuneConfig: Equatable, Sendable {
    public var fontFamily: String = "JetBrains Mono"
    public var fontSize: Double = 13
    public var theme: String = "paper"
    public var lineHeight: Double = 1.2
    public var paddingX: Double = 16
    public var paddingY: Double = 12
    public var cursorStyle: CursorShape = .bar
    public var cursorBlink: Bool = false
    public var scrollback: Int = 10_000
    public var optionAsMeta: Bool = true
    /// Experimental: draw the terminal with the GPU (Metal) via SwiftTerm. Off by default: in
    /// testing it was slower than CPU drawing for heavy output. Falls back if Metal fails.
    public var gpuRendering: Bool = false
    /// Show the "New session" panel above the input editor.
    public var showWelcome: Bool = true
    /// Show the shell's own prompt (PS1) in each block instead of Rune's context chips.
    public var honorPrompt: Bool = false
    /// Rune editor, or type straight into zsh.
    public var inputMode: InputStyle = .editor
    /// Master switch for AI. Off: Rune never contacts Ollama and hides every AI affordance.
    public var aiEnabled: Bool = true
    /// Explicit Ollama URL; nil means $OLLAMA_HOST or http://localhost:11434.
    public var ollamaEndpoint: String?
    /// The model the user picked; falls back to the first installed model if it's gone.
    public var aiModel: String?
    /// Send the last (or selected) block's command and output along with AI requests.
    public var aiIncludeBlockContext: Bool = true
    /// Explicit shell path. `nil` means use $SHELL / the account's login shell.
    public var shell: String?
    /// Folder (iCloud Drive, dotfiles repo, …) to read config/themes/workflows from.
    public var syncPath: String?
    /// System-wide shortcut that shows or hides Rune ("ctrl+`", "option+space"…, or "off").
    public var globalHotkey: String = "ctrl+`"
    /// What the hotkey opens: "window" (bring Rune forward) or "quick" (Quick Terminal
    /// sliding down from the top of the screen).
    public var hotkeyOpens: String = "window"
    /// Rune Recall: keep a searchable history of commands and their output on this Mac.
    public var recallEnabled: Bool = true
    /// Days of Recall history to keep.
    public var recallDays: Double = 90
    /// Mask API keys and tokens in terminal output (click one to reveal it).
    public var hideSecrets: Bool = true
    /// Reopen the previous windows, tabs, splits and folders at launch.
    public var restoreSession: Bool = true
    /// Saved commands shown in the command palette.
    public var workflows: [Workflow] = []
    /// Post a macOS notification when a long command finishes while Rune isn't in front
    /// (or its tab isn't visible).
    public var notifyWhenDone: Bool = true
    /// How long a command must run before its completion is worth a notification.
    public var notifyAfterSeconds: Double = 10

    public init() {}

    public static let defaults = RuneConfig()

    /// Keys understood at the top level of config.json. Anything else produces a warning
    /// (keys starting with `_` or `$` are allowed for comments / schema hints).
    public static let knownKeys: Set<String> = [
        "fontFamily", "fontSize", "lineHeight", "theme", "paddingX", "paddingY", "cursorStyle",
        "cursorBlink", "scrollback", "optionAsMeta", "showWelcome", "honorPrompt", "inputMode", "shell",
        "aiEnabled", "ollamaEndpoint", "aiModel", "aiIncludeBlockContext",
        "syncPath", "hosts", "workflows", "notifyWhenDone", "notifyAfterSeconds", "gpuRendering", "restoreSession", "hideSecrets", "recallEnabled", "recallDays", "globalHotkey", "hotkeyOpens",
    ]

    /// Written to ~/.config/rune/config.json on first launch.
    public static let defaultFileContents = """
    {
      "fontFamily": "JetBrains Mono",
      "fontSize": 13,
      "lineHeight": 1.2,
      "theme": "paper",
      "paddingX": 16,
      "paddingY": 12,
      "cursorStyle": "bar",
      "cursorBlink": false,
      "scrollback": 10000,
      "optionAsMeta": true,
      "showWelcome": true,
      "honorPrompt": false,
      "inputMode": "editor",
      "shell": null,
      "aiEnabled": true,
      "ollamaEndpoint": null,
      "aiModel": null,
      "aiIncludeBlockContext": true,
      "syncPath": null,
      "hosts": {}
    }

    """
}

extension RuneConfig {
    /// Decodes a merged JSON dictionary field by field. Invalid values keep their default
    /// and add a human-readable warning instead of failing the whole file.
    public init(dictionary: [String: Any], warnings: inout [String]) {
        self.init()
        var reader = FieldReader(dictionary: dictionary)

        if let v = reader.string("fontFamily"), !v.isEmpty { fontFamily = v }
        if let v = reader.number("fontSize", range: 6...72) { fontSize = v }
        if let v = reader.number("lineHeight", range: 0.8...3) { lineHeight = v }
        if let v = reader.string("theme"), !v.isEmpty { theme = v }
        if let v = reader.number("paddingX", range: 0...200) { paddingX = v }
        if let v = reader.number("paddingY", range: 0...200) { paddingY = v }
        if let v = reader.string("cursorStyle") {
            if let shape = CursorShape(rawValue: v.lowercased()) {
                cursorStyle = shape
            } else {
                reader.warnings.append("cursorStyle \"\(v)\" is not one of bar, block, underline; using \(cursorStyle.rawValue)")
            }
        }
        if let v = reader.bool("cursorBlink") { cursorBlink = v }
        if let v = reader.number("scrollback", range: 0...1_000_000) { scrollback = Int(v) }
        if let v = reader.bool("optionAsMeta") { optionAsMeta = v }
        if let v = reader.bool("gpuRendering") { gpuRendering = v }
        if let v = reader.bool("showWelcome") { showWelcome = v }
        if let v = reader.bool("honorPrompt") { honorPrompt = v }
        if let v = reader.string("inputMode") {
            if let style = InputStyle(rawValue: v.lowercased()) {
                inputMode = style
            } else {
                reader.warnings.append("inputMode \"\(v)\" is not one of editor, shell; using editor")
            }
        }
        shell = reader.optionalString("shell")
        if let v = reader.bool("aiEnabled") { aiEnabled = v }
        ollamaEndpoint = reader.optionalString("ollamaEndpoint")
        aiModel = reader.optionalString("aiModel")
        if let v = reader.bool("aiIncludeBlockContext") { aiIncludeBlockContext = v }
        syncPath = reader.optionalString("syncPath")
        if let raw = dictionary["workflows"], !(raw is NSNull) {
            workflows = Workflow.parse(raw, warnings: &reader.warnings)
        }
        if let v = reader.bool("notifyWhenDone") { notifyWhenDone = v }
        if let v = reader.bool("restoreSession") { restoreSession = v }
        if let v = reader.bool("hideSecrets") { hideSecrets = v }
        if let v = reader.bool("recallEnabled") { recallEnabled = v }
        if let v = reader.string("globalHotkey") { globalHotkey = v.isEmpty ? "off" : v }
        if let v = reader.string("hotkeyOpens") {
            if ["window", "quick"].contains(v) { hotkeyOpens = v } else { reader.warnings.append("hotkeyOpens \"\(v)\" is not one of window, quick; using window") }
        }
        if let v = reader.number("recallDays", range: 1...3650) { recallDays = v }
        if let v = reader.number("notifyAfterSeconds", range: 1...3600) { notifyAfterSeconds = v }

        for key in dictionary.keys.sorted() where !Self.knownKeys.contains(key) {
            if key.hasPrefix("_") || key.hasPrefix("$") { continue }
            reader.warnings.append("Unknown setting \"\(key)\" ignored")
        }
        warnings.append(contentsOf: reader.warnings)
    }
}

/// Small typed accessor over a JSON dictionary that records type errors.
private struct FieldReader {
    let dictionary: [String: Any]
    var warnings: [String] = []

    mutating func string(_ key: String) -> String? {
        guard let raw = dictionary[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else {
            warnings.append("\(key) should be a string; using default")
            return nil
        }
        return value
    }

    /// Like `string`, but `null` / empty string are valid and mean "unset".
    mutating func optionalString(_ key: String) -> String? {
        guard let value = string(key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    mutating func number(_ key: String, range: ClosedRange<Double>) -> Double? {
        guard let raw = dictionary[key], !(raw is NSNull) else { return nil }
        // JSONSerialization bridges booleans to NSNumber too; reject them explicitly.
        guard let number = raw as? NSNumber, !number.isBool else {
            warnings.append("\(key) should be a number; using default")
            return nil
        }
        let value = number.doubleValue
        guard range.contains(value) else {
            warnings.append("\(key) \(value) is outside \(Int(range.lowerBound))–\(Int(range.upperBound)); using default")
            return nil
        }
        return value
    }

    mutating func bool(_ key: String) -> Bool? {
        guard let raw = dictionary[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, number.isBool else {
            warnings.append("\(key) should be true or false; using default")
            return nil
        }
        return number.boolValue
    }
}

extension NSNumber {
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}
