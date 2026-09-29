import Foundation

/// Scores how well a typed query matches a candidate, for the command palette.
///
/// Every query character must appear in the candidate in order (case-insensitive). Matches
/// score higher when they are consecutive, start a word, or start the candidate, and lower
/// when spread out, so "nt" ranks "New Tab" above "Show Next Tab".
public enum FuzzyMatch {
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate)
        let lowered = haystack.map { Character($0.lowercased()) }

        var score = 0
        var index = 0
        var previousMatch = -2
        for character in needle {
            guard let found = lowered[index...].firstIndex(of: character) else { return nil }
            if found == previousMatch + 1 {
                score += 12 // consecutive run
            } else if found > 0 {
                score -= min(found - index, 8) // gap
            }
            if found == 0 {
                score += 20
            } else if isWordStart(haystack, at: found) {
                score += 10
            }
            previousMatch = found
            index = found + 1
        }
        // Prefer shorter candidates when everything else is equal.
        return score * 4 - haystack.count / 4
    }

    private static func isWordStart(_ text: [Character], at index: Int) -> Bool {
        let previous = text[index - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "/" || previous == "." { return true }
        return previous.isLowercase && text[index].isUppercase
    }
}
