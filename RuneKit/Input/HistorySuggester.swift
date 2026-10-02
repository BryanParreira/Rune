import Foundation

/// The grey suggestion after the caret, fast enough to run on every keystroke: the newest
/// history entry that starts with what's typed. Each extra character only searches the
/// entries that matched before it, and comparisons are on UTF-8 bytes.
public final class HistorySuggester {
    private var sourceCount = -1
    private var sourceLast: String?
    private var lastPrefix: [UInt8] = []
    /// Indices into the entries that start with `lastPrefix`, oldest first.
    private var candidates: [Int] = []
    /// Each entry's UTF-8 bytes, kept until the history changes.
    private var entryBytes: [[UInt8]] = []

    public init() {}

    /// Same answer as `CommandHistory.suggestion(for:)`.
    public func suggestion(for prefix: String, in entries: [String]) -> String? {
        guard !prefix.isEmpty, !prefix.hasPrefix(" ") else { return nil }
        let bytes = Array(prefix.utf8)
        let sameEntries = entries.count == sourceCount && entries.last == sourceLast
        if !sameEntries { entryBytes = entries.map { Array($0.utf8) } }
        let pool: [Int]
        if sameEntries, !lastPrefix.isEmpty, bytes.starts(with: lastPrefix) {
            pool = candidates
        } else {
            pool = Array(entries.indices)
        }
        // Entries at least as long as the prefix that start with it (equal ones are kept so
        // narrowing further still finds longer ones; they're skipped when answering).
        let count = bytes.count
        candidates = pool.filter { index in
            let entry = entryBytes[index]
            return entry.count >= count && entry[0..<count] == bytes[0..<count]
        }
        sourceCount = entries.count
        sourceLast = entries.last
        lastPrefix = bytes
        guard let newest = candidates.last(where: { entryBytes[$0].count > count }) else { return nil }
        return entries[newest]
    }
}
