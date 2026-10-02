import Foundation

/// Rune's input editor inside remote and nested shells (ssh, telnet, docker exec…), the way
/// the local zsh integration works: once the other side shows a shell prompt, and the user
/// agrees, Rune types a small setup script into that session that makes the shell report its
/// prompts and commands. Logins (passwords, host keys, 2FA) always go straight to the program.
public enum RemoteShell {
    /// Commands that open a shell somewhere else, or as someone else. telnet, rlogin and rsh
    /// are left out on purpose: they usually reach routers and other devices whose command
    /// line isn't a shell, where typing a setup script would be wrong. Their logins simply
    /// work as in any terminal.
    public static func isLoginCommand(_ command: String) -> Bool {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard var first = words.first else { return false }
        // `env FOO=1 ssh …`, `command ssh …`
        var rest = Array(words.dropFirst())
        while ["env", "command", "exec", "nocorrect"].contains(first) || first.contains("="), let next = rest.first {
            first = next
            rest.removeFirst()
        }
        let name = (first as NSString).lastPathComponent
        switch name {
        case "ssh", "mosh", "et", "sshpass", "autossh", "su", "nsenter":
            return true
        case "sudo":
            return rest.contains { ["-i", "-s", "--login", "--shell", "-u"].contains($0) || $0 == "su" || $0.hasSuffix("sh") }
        case "docker", "podman", "nerdctl":
            return rest.first == "exec" && rest.contains { $0.hasPrefix("-") && $0.contains("i") && $0.contains("t") }
                || rest.first == "run" && rest.contains { $0.hasPrefix("-") && $0.contains("i") && $0.contains("t") }
        case "kubectl", "oc":
            return rest.first == "exec" && rest.contains { $0 == "-it" || $0 == "-ti" || $0 == "--stdin" || $0 == "-i" }
        case "vagrant":
            return rest.first == "ssh"
        case "gcloud":
            return rest.starts(with: ["compute", "ssh"]) || rest.contains("ssh")
        case "aws":
            return rest.starts(with: ["ssm", "start-session"])
        case "lxc", "incus":
            return rest.first == "exec" || rest.first == "shell"
        default:
            return false
        }
    }

    /// Whether the text before the cursor looks like a POSIX shell prompt (user@host:~$ ,
    /// root# , % , ❯ ) rather than a login, password or yes/no question.
    public static func looksLikeShellPrompt(_ beforeCursor: String) -> Bool {
        let line = beforeCursor.replacingOccurrences(of: "\u{0}", with: " ")
        guard let last = line.last(where: { $0 != " " }), line.hasSuffix(" ") || last == "$" || last == "#" else { return false }
        guard ["$", "#", "%", ">", "❯", "➜", "λ", "»"].contains(String(last)) else { return false }
        let lower = line.lowercased()
        for word in ["password", "passphrase", "login:", "username", "verification code", "(yes/no", "otp", "token"] where lower.contains(word) {
            return false
        }
        return line.trimmingCharacters(in: .whitespaces).count >= 1
    }

    /// Printed by the script as its last step, so Rune knows the output it hid is over.
    public static let readyMarker = "\u{1b}]6973;remote-ready=1\u{7}"

    /// The setup script typed into the remote shell (bash and zsh). Lines start with a space
    /// so they stay out of shell history; it only changes this session (no files).
    /// The server's prompt is hidden like a local tab's (Rune shows the host and folder
    /// itself) unless `keepPrompt` (the "honor my prompt" setting); it's set again at every
    /// prompt so themes that rebuild it can't bring it back.
    public static func bootstrapScript(keepPrompt: Bool) -> String {
        let zshPrompt = keepPrompt ? "" : #" PS1=$'\n%{\e]133;A\a%}\n%{\e]133;B\a\e[?25l%}'; RPS1=''; RPROMPT='';"#
        let zshOnce = keepPrompt ? #"  PS1=$'\n%{\e]133;A\a%}\n'"$PS1"$'%{\e]133;B\a\e[?25l%}'"# + "\n" : ""
        let bashPrompt = keepPrompt ? "" : #" PS1='\n\[\033]133;A\007\]\n\[\033]133;B\007\033[?25l\]'; PS2='';"#
        let bashOnce = keepPrompt ? #"  PS1='\n\[\033]133;A\007\]\n'"$PS1"'\[\033]133;B\007\033[?25l\]'"# + "\n" : ""
        return #"""
         if [ -n "$ZSH_VERSION" ]; then
          setopt hist_ignore_space
          __rune_r_status() { __rune_r_rc=$?; }
          __rune_r_precmd() { printf '\033]133;D;%s\007\033]6973;rcwd=%s\007' "$__rune_r_rc" "$PWD";\#(zshPrompt) }
          __rune_r_preexec() { printf '\033]133;C\007\033[?25h'; }
          typeset -ga precmd_functions preexec_functions
          precmd_functions=(__rune_r_status ${precmd_functions:#__rune_r_*} __rune_r_precmd); preexec_functions+=(__rune_r_preexec)
        \#(zshOnce) elif [ -n "$BASH_VERSION" ]; then
          HISTCONTROL="ignorespace${HISTCONTROL:+:$HISTCONTROL}"
          __rune_r_status() { __rune_r_rc=$?; __rune_r_ready=0; }
          __rune_r_precmd() { printf '\033]133;D;%s\007\033]6973;rcwd=%s\007' "$__rune_r_rc" "$PWD";\#(bashPrompt) __rune_r_ready=1; }
          __rune_r_debug() { [ "$__rune_r_ready" = 1 ] || return 0; [ -n "$COMP_LINE" ] && return 0; __rune_r_ready=0; printf '\033]133;C\007\033[?25h'; }
          PROMPT_COMMAND="__rune_r_status;${PROMPT_COMMAND:+$PROMPT_COMMAND;}__rune_r_precmd"
          if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
           PS0='$(__rune_r_debug)'
          else
           trap '__rune_r_debug' DEBUG
          fi
        \#(bashOnce) fi
         printf '\033]6973;remote-ready=1\007\033]6973;remote=%s@%s\007' "$(id -un 2>/dev/null || echo "$USER")" "$(hostname 2>/dev/null | cut -d. -f1)"
        """#
    }

    public static let bootstrapScript = bootstrapScript(keepPrompt: false)

    /// Host label from a login command, for the "use Rune's input on …?" question
    /// (`ssh -p 22 me@box.example.com` → box.example.com).
    public static func hostLabel(for command: String) -> String {
        var words = command.split(separator: " ").map(String.init)
        // Skip `VAR=value` prefixes and wrappers like env.
        while let first = words.first, first.contains("=") || ["env", "command", "exec"].contains(first) { words.removeFirst() }
        let flagsWithValues: Set<String> = ["-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-m", "-S", "-W", "-E"]
        var skip = false
        for word in words.dropFirst() {
            if skip { skip = false; continue }
            if flagsWithValues.contains(word) { skip = true; continue }
            if word.hasPrefix("-") { continue }
            let host = word.split(separator: "@").last.map(String.init) ?? word
            return host.split(separator: ":").first.map(String.init) ?? host
        }
        return words.first ?? "this session"
    }
}
