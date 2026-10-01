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

    /// Every occurrence of `query` in `rows` (in the order given), not overlapping.
    public static func find(_ query: String, in rows: [(row: Int, text: String)], caseSensitive: Bool = false, limit: Int = 10_000) -> [Match] {
        guard !query.isEmpty else { return [] }
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
}
