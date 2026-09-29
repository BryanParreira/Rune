import Foundation

/// Shell snippets in Markdown that Rune offers to run. The command is only ever placed in
/// the terminal's input; the user presses Enter.
public enum RunnableSnippet {
    static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "shell", "console", "shell-session", "terminal", "shellsession"]

    /// The command(s) to put in the terminal for a fenced block, or nil if it isn't shell.
    public static func command(from code: String, language: String) -> String? {
        let language = language.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let lines = code.components(separatedBy: "\n")
        let promptLines = lines.filter { isPromptLine($0) }

        // Transcripts ("$ cmd" followed by output): keep only the commands.
        if !promptLines.isEmpty, language.isEmpty || shellLanguages.contains(language) {
            var commands: [String] = []
            var continuing = false
            for line in lines {
                if isPromptLine(line) {
                    let command = stripPrompt(line)
                    commands.append(command)
                    continuing = command.hasSuffix("\\")
                } else if continuing {
                    commands.append(line)
                    continuing = line.hasSuffix("\\")
                }
            }
            let joined = commands.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }

        guard shellLanguages.contains(language) else { return nil }
        // Interactive zsh doesn't accept `#` comments by default, so comment lines are dropped.
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func isPromptLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        return trimmed.hasPrefix("$ ") || trimmed.hasPrefix("% ")
    }

    private static func stripPrompt(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " })
        return String(trimmed.dropFirst(2))
    }
}
