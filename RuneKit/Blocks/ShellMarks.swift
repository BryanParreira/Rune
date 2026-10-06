import Foundation

/// Events reported by Rune's shell integration through OSC sequences.
///
/// Standard FinalTerm/OSC 133 marks:
/// - `A` prompt start, `B` command (input) start, `C` output start, `D[;exit]` command finished.
///
/// Rune's private OSC 6973 carries metadata as `key=value` (value percent-encoded):
/// - `hello=<version>` integration loaded, `cwd=<path>`, `cmd=<command text>`.
///   Version 2 binds `ShellLineKeys` (clear the line, hand it to Rune).
public enum ShellMark: Equatable, Sendable {
    case promptStart
    case commandStart
    case outputStart
    case commandFinished(exitCode: Int32?)
    case integrationReady(version: String)
    case currentDirectory(String)
    case commandText(String)
    /// Aliases and functions defined in the user's shell (space separated).
    case shellNames([String])
    /// The shell's PATH after the user's config ran (GUI apps start with a minimal PATH).
    case shellPath(String)
    /// A remote/nested shell set up by Rune reports who and where it is (`user@host`).
    case remoteHost(String)
    /// The remote shell's working directory (a path on the other machine).
    case remoteDirectory(String)
    /// The remote setup script finished.
    case remoteReady
    /// What was in the shell's line when Rune asked for it: keys typed while the last
    /// command ran, handed to Rune's editor (empty when nothing was typed).
    case typeahead(String)
}

/// Keys Rune's integrations bind in the shell's line editor (integration version 2).
public enum ShellLineKeys {
    /// Clears the line: sent before each command Rune writes, so keys typed while the last
    /// command ran can't end up in front of it.
    public static let clear: [UInt8] = Array("\u{1b}[9972~".utf8)
    /// Reports the line (`input=`) and clears it: sent at the prompt after keys were typed
    /// into a running command, so they reappear in Rune's editor.
    public static let take: [UInt8] = Array("\u{1b}[9973~".utf8)
    public static let minimumVersion = 2

    public static func supported(integrationVersion: String?) -> Bool {
        (integrationVersion.flatMap { Int($0) } ?? 0) >= minimumVersion
    }
}

public enum ShellMarkParser {
    public static let runeOSC = 6973

    /// Parses the payload of an OSC 133 sequence (everything after `133;`).
    public static func parse133(_ payload: String) -> ShellMark? {
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard let action = fields.first, action.count == 1 else { return nil }
        switch action {
        case "A": return .promptStart
        case "B": return .commandStart
        case "C": return .outputStart
        case "D":
            // "D", "D;0", "D;127", or "D;;aid=…" — options after the exit code are ignored.
            let code = fields.count > 1 ? Int32(fields[1]) : nil
            return .commandFinished(exitCode: code)
        default: return nil
        }
    }

    /// Parses the payload of Rune's private OSC (everything after `6973;`).
    public static func parseRune(_ payload: String) -> ShellMark? {
        guard let eq = payload.firstIndex(of: "=") else { return nil }
        let key = payload[..<eq]
        let raw = String(payload[payload.index(after: eq)...])
        let value = percentDecode(raw)
        switch key {
        case "hello": return .integrationReady(version: value)
        case "cwd": return value.isEmpty ? nil : .currentDirectory(value)
        case "cmd": return .commandText(value)
        case "names": return .shellNames(value.split(separator: " ").map(String.init))
        case "path": return value.isEmpty ? nil : .shellPath(value)
        case "remote": return value.isEmpty ? nil : .remoteHost(value)
        case "rcwd": return value.isEmpty ? nil : .remoteDirectory(value)
        case "remote-ready": return .remoteReady
        case "input": return .typeahead(value)
        // fish reports prompt/command marks here instead of OSC 133 (see rune.fish).
        case "mark": return parse133(value)
        default: return nil
        }
    }

    /// Decodes `%XX` escapes; malformed escapes are kept literally. Works on bytes so
    /// multi-byte UTF-8 split across escapes decodes correctly.
    public static func percentDecode(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.utf8.count)
        var iterator = Array(s.utf8)[...]
        while let byte = iterator.popFirst() {
            if byte == UInt8(ascii: "%"), iterator.count >= 2,
               let hi = hexValue(iterator[iterator.startIndex]),
               let lo = hexValue(iterator[iterator.startIndex + 1]) {
                bytes.append(hi << 4 | lo)
                iterator = iterator.dropFirst(2)
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
