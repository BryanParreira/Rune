import Foundation

/// Finding text in terminal output, row by row (a row is one line of the grid).
public enum OutputSearch {
    public struct Match: Equatable, Sendable {
        /// Scroll-invariant row.
        public let row: Int
        /// First column and length, in characters of the row's text.
        public let column: Int
        public let length: Int
    }

    /// Whether `query` is a usable regular expression.
    public static func isValidPattern(_ query: String) -> Bool {
        (try? NSRegularExpression(pattern: query)) != nil
    }

    /// Every occurrence of `query` in `rows` (in the order given), not overlapping. With
    /// `regex`, `query` is a regular expression (no matches when it isn't valid; empty
    /// matches are skipped).
    public static func find(_ query: String, in rows: [(row: Int, text: String)], caseSensitive: Bool = false,
                            regex: Bool = false, limit: Int = 10_000) -> [Match] {
        guard !query.isEmpty else { return [] }
        if regex { return findPattern(query, in: rows, caseSensitive: caseSensitive, limit: limit) }
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive, .literal]
        var matches: [Match] = []
        for (row, text) in rows where text.count >= query.count {
            var searchStart = text.startIndex
            while searchStart < text.endIndex, let range = text.range(of: query, options: options, range: searchStart..<text.endIndex) {
                matches.append(Match(row: row, column: text.distance(from: text.startIndex, to: range.lowerBound),
                                     length: text.distance(from: range.lowerBound, to: range.upperBound)))
                if matches.count >= limit { return matches }
                searchStart = range.upperBound
            }
        }
        return matches
    }

    private static func findPattern(_ query: String, in rows: [(row: Int, text: String)], caseSensitive: Bool, limit: Int) -> [Match] {
        guard let expression = try? NSRegularExpression(pattern: query, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        var matches: [Match] = []
        for (row, text) in rows {
            for result in expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            where result.range.length > 0 {
                guard let range = Range(result.range, in: text) else { continue }
                matches.append(Match(row: row, column: text.distance(from: text.startIndex, to: range.lowerBound),
                                     length: text.distance(from: range.lowerBound, to: range.upperBound)))
                if matches.count >= limit { return matches }
            }
        }
        return matches
    }
}
