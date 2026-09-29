import Foundation

/// What the model is told about the user's situation.
public struct AIContext: Equatable, Sendable {
    public var request: String
    public var cwd: String
    public var osVersion: String
    public var shell: String
    public var gitBranch: String?
    /// Names of entries in the working directory (no contents), to ground suggestions.
    public var directoryListing: [String]
    /// A block the user attached (selected) or the most recent one, if the setting allows.
    public var blockCommand: String?
    public var blockOutput: String?
    public var blockExitCode: Int32?

    public init(request: String, cwd: String, osVersion: String, shell: String,
                gitBranch: String? = nil, directoryListing: [String] = [],
                blockCommand: String? = nil, blockOutput: String? = nil, blockExitCode: Int32? = nil) {
        self.request = request
        self.cwd = cwd
        self.osVersion = osVersion
        self.shell = shell
        self.gitBranch = gitBranch
        self.directoryListing = directoryListing
        self.blockCommand = blockCommand
        self.blockOutput = blockOutput
        self.blockExitCode = blockExitCode
    }
}

public enum AIPrompt {
    /// Output is truncated to its last characters (errors are usually at the end).
    public static let maxOutputCharacters = 4_000
    /// At most this many directory entries are listed.
    public static let maxListing = 60

    public static let systemPrompt = """
    You are the AI assistant built into Rune, a terminal app on the user's Mac. The user is a \
    developer working in their shell. Help with anything they ask: running and fixing commands, \
    explaining errors and output, programming questions, git, package managers, build tools, \
    scripting, system administration, and general technical concepts.

    How to answer:
    - Answer the question that was asked. Be direct and concise, but complete: explain when \
    explaining is what helps, and keep it short when a command is all that's needed.
    - Use Markdown. Use short paragraphs or lists; avoid headings for short answers.
    - Put every command meant to be run in the user's terminal in its own ```sh block, one \
    command (or one pipeline) per block, so Rune can offer a Run button for each. Use several \
    blocks for multi-step tasks, in the order to run them.
    - Use other languages' fences (```python, ```json, ```swift…) for code that is not a shell \
    command. Never put file contents or code meant for an editor in a ```sh block.
    - Commands must work in the user's shell on macOS (BSD userland; Homebrew is common). \
    Prefer commands that fit the working directory and files you were told about.
    - Don't invent file names, flags, or output. If something is unknown, say so, or use a \
    placeholder like <file> and say what to replace.
    - If a command deletes, overwrites, force-pushes, or needs sudo, say so plainly before it.
    - If the request is ambiguous, give the most likely answer and note the assumption; ask a \
    short clarifying question only when you really can't proceed.
    - The user reviews every command before it runs. Never claim you ran anything or saw \
    output you weren't given.
    """

    /// The user turn for a request, with a compact environment summary.
    public static func userMessage(for context: AIContext) -> String {
        var lines: [String] = []
        lines.append("Environment: \(context.osVersion), shell \(context.shell)")
        var cwdLine = "Working directory: \(context.cwd)"
        if let branch = context.gitBranch { cwdLine += " (git branch \(branch))" }
        lines.append(cwdLine)
        if !context.directoryListing.isEmpty {
            let shown = context.directoryListing.prefix(maxListing).joined(separator: ", ")
            let more = context.directoryListing.count > maxListing ? ", … (\(context.directoryListing.count - maxListing) more)" : ""
            lines.append("Files here: \(shown)\(more)")
        }
        var text = lines.joined(separator: "\n") + "\n"
        if let command = context.blockCommand, !command.isEmpty {
            text += "\nRelated command: \(command)"
            if let code = context.blockExitCode { text += " (exit code \(code))" }
            text += "\n"
            if let output = context.blockOutput, !output.isEmpty {
                text += "Its output:\n```\n\(truncate(output))\n```\n"
            }
        }
        text += "\n\(context.request)"
        return text
    }

    /// Full message list: system prompt, earlier turns of this conversation, then the new request.
    public static func messages(for context: AIContext, history: [OllamaClient.ChatMessage] = []) -> [OllamaClient.ChatMessage] {
        messages(system: systemPrompt, history: history, user: userMessage(for: context))
    }

    public static func messages(system: String, history: [OllamaClient.ChatMessage], user: String) -> [OllamaClient.ChatMessage] {
        [OllamaClient.ChatMessage(role: "system", content: system)]
            + history
            + [OllamaClient.ChatMessage(role: "user", content: user)]
    }

    public static func explainErrorRequest(command: String) -> String {
        "The command `\(command)` failed. What went wrong, and how do I fix it?"
    }

    static func truncate(_ output: String) -> String {
        guard output.count > maxOutputCharacters else { return output }
        return "…(truncated)…\n" + output.suffix(maxOutputCharacters)
    }

    // MARK: - Reading replies

    /// A piece of a reply, for rendering.
    public enum Segment: Equatable, Sendable {
        /// Markdown prose.
        case text(String)
        /// A shell command the user can run (```sh / bash / zsh / shell / console, or an
        /// untagged fence). `complete` is false while the block is still streaming.
        case command(String, complete: Bool)
        /// Code in another language: shown, copyable, never runnable.
        case code(language: String, String, complete: Bool)
    }

    static let shellTags: Set<String> = ["", "sh", "bash", "zsh", "shell", "console", "terminal", "command"]

    public static func segments(from reply: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var fenceTag: String?
        var fenceBody: [String] = []

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.text(text)) }
            prose.removeAll()
        }
        func flushFence(complete: Bool) {
            guard let tag = fenceTag else { return }
            if shellTags.contains(tag) {
                let command = fenceBody
                    .map { $0.hasPrefix("$ ") ? String($0.dropFirst(2)) : $0 }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty { segments.append(.command(command, complete: complete)) }
            } else {
                let code = fenceBody.joined(separator: "\n")
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.code(language: tag, code, complete: complete))
                }
            }
            fenceTag = nil
            fenceBody.removeAll()
        }

        for line in reply.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if fenceTag == nil {
                    flushProse()
                    fenceTag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                } else {
                    flushFence(complete: true)
                }
                continue
            }
            if fenceTag != nil { fenceBody.append(line) } else { prose.append(line) }
        }
        flushProse()
        flushFence(complete: false)
        return segments
    }

    /// Completed shell commands in a reply, in order.
    public static func commands(in reply: String) -> [String] {
        segments(from: reply).compactMap {
            if case .command(let command, true) = $0 { return command }
            return nil
        }
    }

    /// The first complete shell command in a reply (nil if none yet).
    public static func extractCommand(from reply: String) -> String? {
        commands(in: reply).first
    }
}
