import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut (e.g. ⌃`) that shows or hides Rune from any app. Uses the Carbon
/// hotkey API, which needs no Accessibility permission.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// Called on the main thread when the shortcut is pressed.
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var current: String?
    /// The last spec macOS refused because another app already has it.
    private(set) var taken: String?

    private init() {}

    /// Registers `spec` ("ctrl+`", "option+space", "cmd+shift+t"…); nil or "off" removes it.
    /// Returns false if the spec can't be parsed or macOS refuses it (already taken).
    @discardableResult
    func register(_ spec: String?) -> Bool {
        unregister()
        guard let spec, spec.lowercased() != "off" else { return true }
        guard let (keyCode, modifiers) = Self.parse(spec) else { return false }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x52554E45), id: 1) // "RUNE"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            hotKeyRef = nil
            taken = spec
            return false
        }
        current = spec
        taken = nil
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        current = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.shared.onPress?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    // MARK: Parsing

    /// "ctrl+option+t" → (key code, Carbon modifiers).
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        let parts = spec.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let keyName = parts.last, let keyCode = keyCodes[keyName] else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        let isFunctionKey = functionKeys.values.contains(keyCode)
        // A bare key would swallow ordinary typing everywhere; function keys are the exception.
        guard modifiers != 0 || isFunctionKey else { return nil }
        // ⌘ or ⇧⌘ with a letter, digit or symbol is some app's command (⌘Q, ⌘C, ⇧⌘T…); taken
        // system-wide it would stop working in every app.
        let commandOnly = modifiers & UInt32(cmdKey) != 0 && modifiers & ~UInt32(cmdKey | shiftKey) == 0
        guard !commandOnly || isFunctionKey || keyName == "space" else { return nil }
        return (UInt32(keyCode), modifiers)
    }

    /// The spec for a key press in a shortcut recorder ("ctrl+option+t"), or nil when it can't
    /// be a global shortcut. Reads the physical key, so it matches what `parse` registers on
    /// any keyboard layout and isn't changed by Shift or Option.
    static func spec(from event: NSEvent) -> String? {
        guard let keyName = keyCodes.first(where: { $0.value == Int(event.keyCode) })?.key else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        let spec = (parts + [keyName]).joined(separator: "+")
        return parse(spec) == nil ? nil : spec
    }

    /// "ctrl+`" → "⌃`" for display.
    static func display(_ spec: String) -> String {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        var symbols = ""
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": symbols += "⌃"
            case "opt", "option", "alt": symbols += "⌥"
            case "shift": symbols += "⇧"
            case "cmd", "command": symbols += "⌘"
            default: symbols += part
            }
        }
        let key = parts.last ?? ""
        let names = ["space": "Space", "return": "↩", "escape": "⎋", "tab": "⇥", "delete": "⌫",
                     "up": "↑", "down": "↓", "left": "←", "right": "→"]
        return symbols + (names[key] ?? key.uppercased())
    }

    private static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "`": kVK_ANSI_Grave, "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "\\": kVK_ANSI_Backslash, "delete": kVK_Delete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E), ("f", kVK_ANSI_F),
            ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R),
            ("s", kVK_ANSI_S), ("t", kVK_ANSI_T), ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]
        for (name, code) in letters { codes[name] = code }
        for (name, code) in functionKeys { codes[name] = code }
        return codes
    }()

    private static let functionKeys: [String: Int] = [
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
        "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13,
        "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
    ]
}
