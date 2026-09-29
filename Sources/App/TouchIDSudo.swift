import AppKit
import LocalAuthentication

/// Lets `sudo` accept Touch ID (or an Apple Watch) instead of a password, via Apple's
/// /etc/pam.d/sudo_local, which macOS keeps across updates. Changing it needs the user's
/// administrator password (the standard macOS prompt); nothing is changed silently.
enum TouchIDSudo {
    static let file = "/etc/pam.d/sudo_local"
    private static let line = "auth       sufficient     pam_tid.so"
    private static let pattern = #"^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so"#

    enum Outcome: Equatable {
        case done
        case cancelled
        case failed(String)
    }

    /// This Mac has Touch ID or an Apple Watch that can approve.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrWatch, error: nil)
    }

    /// pam_tid is active for sudo (in sudo_local, or added to /etc/pam.d/sudo by hand).
    static var isEnabled: Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return false }
        return ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"].contains { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
    }

    /// Turns it on or off with an administrator prompt. Runs the prompt on the main thread.
    static func set(enabled: Bool) -> Outcome {
        let script: String
        if enabled {
            script = """
            f=\(file); \
            [ -f "$f" ] || printf '%s\\n' '# sudo_local: local config file which survives system update and is included for sudo' > "$f"; \
            grep -qE '\(pattern)' "$f" || printf '%s\\n' '\(line)' >> "$f"
            """
        } else {
            script = "[ -f \(file) ] && sed -i '' -E '/\(pattern)/d' \(file); true"
        }
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Rune wants to \(enabled ? "turn on" : "turn off") Touch ID for sudo.\""
        guard let appleScript = NSAppleScript(source: source) else { return .failed("Couldn't prepare the change.") }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "The change didn't go through.")
        }
        return isEnabled == enabled ? .done : .failed("The setting didn't change. Check \(file).")
    }
}
