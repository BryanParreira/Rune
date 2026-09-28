import Foundation

/// What the model is told about the user's situation.
public struct AIContext: Equatable, Sendable {
    public var request: String
    public var cwd: String
    public var osVersion: String
    public var shell: String
    /// A block the user attached (selected) or the most recent one, if the setting allows.
    public var blockCommand: String?
    public var blockOutput: String?
    public var blockExitCode: Int32?

    public init(request: String, cwd: String, osVersion: String, shell: String,
                blockCommand: String? = nil, blockOutput: String? = nil, blockExitCode: Int32? = nil) {
        self.request = request
        self.cwd = cwd
        self.osVersion = osVersion
        self.shell = shell
        self.blockCommand = blockCommand
        self.blockOutput = blockOutput
        self.blockExitCode = blockExitCode
    }
}

public enum AIPrompt {
    /// Output is truncated to its last characters (errors are usually at the end).
    public static let maxOutputCharacters = 4_000

    public static let systemPrompt = """
    You are Rune's terminal assistant on macOS. Help the user accomplish tasks in their shell.
    Rules:
    - Be brief: one or two sentences of explanation at most.
    - When a shell command helps, give exactly one command in a single ```sh fenced block.
    - Commands must work in zsh on macOS (BSD userland, Homebrew available).
    - Never invent file names you have not been told about; use placeholders like <file> instead.
    - Prefer safe commands. If a command deletes or overwrites data, say so explicitly.
    - The user always reviews a command before it runs; never claim you ran anything.
    """

    public static func messages(for context: AIContext) -> [OllamaClient.ChatMessage] {
        var user = "Working directory: \(context.cwd)\nOS: \(context.osVersion)\nShell: \(context.shell)\n"
        if let command = context.blockCommand, !command.isEmpty {
            user += "\nPrevious command: \(command)"
            if let code = context.blockExitCode { user += " (exit code \(code))" }
            user += "\n"
            if let output = context.blockOutput, !output.isEmpty {
                user += "Its output:\n```\n\(truncate(output))\n```\n"
            }
        }
        user += "\nRequest: \(context.request)"
        return [
            OllamaClient.ChatMessage(role: "system", content: systemPrompt),
            OllamaClient.ChatMessage(role: "user", content: user),
        ]
    }

    public static func explainErrorRequest(command: String) -> String {
        "The command `\(command)` failed. Explain the error in one or two sentences and give a command that fixes it, if there is one."
    }

    static func truncate(_ output: String) -> String {
        guard output.count > maxOutputCharacters else { return output }
        return "…(truncated)…\n" + output.suffix(maxOutputCharacters)
    }

    /// The first fenced code block in a reply, as a runnable command (nil if none).
    /// Accepts ```sh / ```bash / ```zsh / ```shell / ``` and strips leading "$ " prompts.
    public static func extractCommand(from reply: String) -> String? {
        let shellTags: Set<String> = ["", "sh", "bash", "zsh", "shell", "console", "terminal"]
        var lines = reply.components(separatedBy: "\n")[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else { continue }
            let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            guard shellTags.contains(tag) else { continue }
            var body: [String] = []
            while let inner = lines.first {
                lines = lines.dropFirst()
                if inner.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    let command = body
                        .map { $0.hasPrefix("$ ") ? String($0.dropFirst(2)) : $0 }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return command.isEmpty ? nil : command
                }
                body.append(inner)
            }
            return nil // unterminated block: still streaming
        }
        return nil
    }
}
