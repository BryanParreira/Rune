import Foundation

/// Picks the shell to launch: config → $SHELL → account login shell → /bin/zsh.
public enum ShellResolver {
    public static let fallbackShell = "/bin/zsh"

    public static func resolve(
        configured: String?,
        environment: [String: String],
        accountShell: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        let candidates = [configured, environment["SHELL"], accountShell]
        for case let candidate? in candidates {
            let path = candidate.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/"), isExecutable(path) { return path }
        }
        return fallbackShell
    }

    /// The login shell recorded for the current user in the directory service.
    public static func accountShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let value = String(cString: shell)
        return value.isEmpty ? nil : value
    }

    /// argv[0] for a login shell: "-zsh" for "/bin/zsh".
    public static func loginArgv0(for shellPath: String) -> String {
        "-" + (shellPath as NSString).lastPathComponent
    }

    /// True if the shell is zsh (used later to decide whether integration can be injected).
    public static func isZsh(_ shellPath: String) -> Bool {
        (shellPath as NSString).lastPathComponent == "zsh"
    }
}

/// Builds the environment for the child shell.
public enum ShellEnvironment {
    /// Variables from the launching context that must not leak into Rune's shells.
    static let stripped: Set<String> = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID",
        "ITERM_PROFILE", "SHLVL", "PWD", "OLDPWD", "_", "COLUMNS", "LINES",
        "VSCODE_INJECTION", "VSCODE_GIT_IPC_HANDLE", "VSCODE_GIT_ASKPASS_NODE",
        "VSCODE_GIT_ASKPASS_MAIN", "VSCODE_GIT_ASKPASS_EXTRA_ARGS", "GIT_ASKPASS",
        "XPC_SERVICE_NAME", "__CFBundleIdentifier",
    ]

    public static func build(
        inherited: [String: String],
        currentDirectory: String,
        appVersion: String
    ) -> [String: String] {
        var env = inherited.filter { !stripped.contains($0.key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Rune"
        env["TERM_PROGRAM_VERSION"] = appVersion
        env["PWD"] = currentDirectory
        if (env["LANG"] ?? "").isEmpty {
            env["LANG"] = "en_US.UTF-8"
        }
        if (env["HOME"] ?? "").isEmpty {
            env["HOME"] = NSHomeDirectory()
        }
        return env
    }

    /// Adds the variables that make zsh load Rune's integration from `integrationDirectory`
    /// while still reading the user's own dotfiles (see Resources/ShellIntegration/zsh/.zshenv).
    public static func addZshIntegration(
        to env: inout [String: String],
        integrationDirectory: String,
        honorPrompt: Bool,
        typeInShell: Bool = false
    ) {
        if let userZdotdir = env["ZDOTDIR"], !userZdotdir.isEmpty {
            env["RUNE_USER_ZDOTDIR"] = userZdotdir
        } else {
            env.removeValue(forKey: "RUNE_USER_ZDOTDIR")
        }
        env["ZDOTDIR"] = integrationDirectory
        env["RUNE_INTEGRATION_DIR"] = integrationDirectory
        // Typing at the shell prompt needs the real prompt and a visible cursor.
        env["RUNE_HONOR_PROMPT"] = (honorPrompt || typeInShell) ? "1" : "0"
        env["RUNE_INPUT_MODE"] = typeInShell ? "shell" : "editor"
    }

    /// `KEY=value` array form expected by forkpty/execve, sorted for determinism.
    public static func toArray(_ env: [String: String]) -> [String] {
        env.keys.sorted().compactMap { key in env[key].map { "\(key)=\($0)" } }
    }
}

/// Decodes a waitpid(2) status word.
public enum ProcessExit: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    public init(waitStatus status: Int32) {
        let signal = status & 0x7F
        if signal == 0 {
            self = .exited((status >> 8) & 0xFF)
        } else {
            self = .signaled(signal)
        }
    }

    public var isClean: Bool { self == .exited(0) }
}
