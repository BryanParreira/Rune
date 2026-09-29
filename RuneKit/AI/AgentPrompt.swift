import Foundation

/// Rune Agent: works toward a goal one command at a time. Each step is proposed by the
/// model, run only when the user approves it, and its result is sent back for the next
/// step. Nothing here runs anything.
public enum AgentPrompt {
    /// The agent stops proposing after this many steps.
    public static let maxSteps = 12
    /// Output sent back per step: the last characters (errors are usually at the end).
    public static let maxResultCharacters = 3_000

    public static let systemPrompt = """
    You are Rune Agent, working in the user's terminal on their Mac to reach a goal they \
    gave you. You work one step at a time and the user approves every command before it runs.

    Every reply must be exactly one of:
    1. One short sentence saying what you'll do next and why, then exactly ONE ```sh block \
    containing one command (or one pipeline). After it runs you'll be told its exit code and \
    output.
    2. When the goal is reached, or you can't make progress: a line starting with DONE: and a \
    short summary of what happened. No command.

    Rules:
    - Never use interactive programs (editors, pagers, top, ssh sessions, REPLs). Use \
    non-interactive flags instead: --no-pager, -y, --yes, | head.
    - Keep output short: limit it with head, tail, --oneline, -q, grep.
    - Read before you change: inspect files and state first, and don't guess file names.
    - To create or change a file, use a single command such as cat <<'EOF' > file.
    - Say plainly when a command deletes, overwrites, force-pushes or needs sudo.
    - Commands run in the user's shell on macOS (BSD userland; Homebrew is common).
    - Never claim you ran something or saw output you weren't given.
    """

    /// First message: the goal plus the environment summary.
    public static func goalMessage(for context: AIContext) -> String {
        AIPrompt.userMessage(for: context).replacingOccurrences(
            of: "\n\(context.request)", with: "\nGoal: \(context.request)\nStart with the first step.")
    }

    /// Sent after a step runs. Repeats the goal, since old turns get trimmed.
    public static func resultMessage(goal: String, command: String, exitCode: Int32?, output: String, step: Int) -> String {
        var text = "Step \(step) result: `\(command)` "
        text += exitCode.map { "exited with code \($0)." } ?? "finished."
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text += "\n(no output)"
        } else {
            let shown = trimmed.count > maxResultCharacters ? "…(truncated)…\n" + trimmed.suffix(maxResultCharacters) : trimmed
            text += "\nOutput:\n```\n\(shown)\n```"
        }
        text += "\n\nGoal: \(goal)\n"
        text += step >= maxSteps
            ? "That was the last step allowed. Reply with DONE: and a summary."
            : "Continue with the next step, or reply DONE: if the goal is reached."
        return text
    }

    public static func skippedMessage(goal: String, command: String) -> String {
        "The user skipped `\(command)`; it did not run. Suggest a different next step, or reply DONE: if there's nothing else to do.\n\nGoal: \(goal)"
    }

    /// What a reply asks for.
    public enum Step: Equatable, Sendable {
        case run(command: String)
        case done(summary: String)
        /// Neither a command nor DONE (the model went off-script): shown as a normal answer.
        case answer
    }

    public static func step(from reply: String) -> Step {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = AIPrompt.extractCommand(from: trimmed)
        if let range = trimmed.range(of: "DONE:", options: [.caseInsensitive]), command == nil {
            return .done(summary: String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let command { return .run(command: command) }
        return .answer
    }
}

/// Flags commands whose effects are hard to undo, so the Run button can warn.
public enum CommandRisk {
    private static let rules: [(pattern: String, reason: String)] = [
        (#"(^|[;&|]\s*)sudo\b"#, "runs as administrator (sudo)"),
        (#"\brm\s+(-[a-zA-Z]*[rRf][a-zA-Z]*\s+)+"#, "deletes files"),
        (#"\bgit\s+push\b.*(\s--force\b|\s-f\b|\s--force-with-lease\b)"#, "force-pushes"),
        (#"\bgit\s+reset\s+--hard\b"#, "discards uncommitted changes"),
        (#"\bgit\s+clean\s+-[a-zA-Z]*f"#, "deletes untracked files"),
        (#"\bgit\s+checkout\s+--\s"#, "discards changes to files"),
        (#"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#, "runs a script from the internet"),
        (#"\b(mkfs|diskutil\s+erase|dd\s+if=)"#, "can erase a disk"),
        (#"\bch(mod|own)\s+-R\b"#, "changes permissions recursively"),
        (#"\bkill(all)?\s+-9\b"#, "force-kills processes"),
        (#"\bdrop\s+(table|database)\b"#, "drops database objects"),
        (#"(^|[^>&0-9])>\s*[^\s>&|]"#, "overwrites a file"),
    ]

    /// Why `command` deserves a second look, or nil.
    public static func reason(for command: String) -> String? {
        let range = NSRange(location: 0, length: (command as NSString).length)
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
            if regex.firstMatch(in: command, range: range) != nil { return rule.reason }
        }
        return nil
    }
}
