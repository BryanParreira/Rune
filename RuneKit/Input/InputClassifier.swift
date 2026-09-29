import Foundation

/// Tells a plain-English question apart from a command, so the editor can point out that
/// ⌘↵ asks AI. It never reroutes input: Enter always runs what was typed.
public enum InputClassifier {
    private static let questionWords: Set<String> = [
        "how", "what", "why", "where", "when", "which", "who", "whats", "what's", "hows", "how's",
        "can", "could", "should", "would", "is", "are", "does", "do", "explain", "tell", "help", "please",
    ]

    public static func looksLikeQuestion(_ text: String, isCommand: (String) -> Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ")
        guard words.count >= 3, let first = words.first?.lowercased() else { return false }
        // Anything that reads like shell syntax is a command.
        if trimmed.contains(where: { "|><$=`;&\\{}[]".contains($0) }) || trimmed.contains(" -") { return false }
        if isCommand(String(words[0])), !questionWords.contains(first) { return false }
        return trimmed.hasSuffix("?") || questionWords.contains(first)
    }
}
