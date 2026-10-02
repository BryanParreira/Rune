import Foundation
import SQLite3

/// Rune Recall: every finished command and its output, searchable, stored only on this Mac.
/// Callers remove secrets before adding. Not thread-safe: use from one queue.
public final class RecallStore {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: Int64
        public var date: Date
        public var directory: String
        public var command: String
        public var output: String
        public var exitCode: Int32?
        public var duration: Double

        public init(id: Int64 = 0, date: Date, directory: String, command: String, output: String, exitCode: Int32?, duration: Double) {
            self.id = id
            self.date = date
            self.directory = directory
            self.command = command
            self.output = output
            self.exitCode = exitCode
            self.duration = duration
        }
    }

    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (or creates) the database; nil if it can't be opened.
    public init?(url: URL) {
        PrivateFiles.makeDirectory(url.deletingLastPathComponent())
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        // Commands and their output: only the owner can read them. SQLite gives the -wal and
        // -shm files the database's permissions; existing ones are tightened too.
        for suffix in ["", "-wal", "-shm"] { PrivateFiles.restrict(URL(fileURLWithPath: url.path + suffix)) }
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY, date REAL NOT NULL, directory TEXT NOT NULL,
            command TEXT NOT NULL, output TEXT NOT NULL, exit INTEGER, duration REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS entries_date ON entries(date);
        CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(command, output, content='entries', content_rowid='id');
        CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
            INSERT INTO entries_fts(rowid, command, output) VALUES (new.id, new.command, new.output); END;
        CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
            INSERT INTO entries_fts(entries_fts, rowid, command, output) VALUES ('delete', old.id, old.command, old.output); END;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    public func add(_ entry: Entry) -> Bool {
        let sql = "INSERT INTO entries(date, directory, command, output, exit, duration) VALUES (?, ?, ?, ?, ?, ?)"
        return withStatement(sql) { statement in
            sqlite3_bind_double(statement, 1, entry.date.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, entry.directory, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, entry.command, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, entry.output, -1, SQLITE_TRANSIENT)
            if let exit = entry.exitCode { sqlite3_bind_int(statement, 5, exit) } else { sqlite3_bind_null(statement, 5) }
            sqlite3_bind_double(statement, 6, entry.duration)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    /// Newest first. An empty query lists recent entries; otherwise every word must appear
    /// (as a prefix) in the command or the output.
    public func search(_ query: String, limit: Int = 200) -> [Entry] {
        let match = Self.ftsQuery(query)
        let sql = match == nil
            ? "SELECT id, date, directory, command, output, exit, duration FROM entries ORDER BY date DESC LIMIT ?"
            : """
              SELECT e.id, e.date, e.directory, e.command, e.output, e.exit, e.duration FROM entries_fts f
              JOIN entries e ON e.id = f.rowid WHERE entries_fts MATCH ? ORDER BY e.date DESC LIMIT ?
              """
        return withStatement(sql) { statement in
            var index: Int32 = 1
            if let match {
                sqlite3_bind_text(statement, index, match, -1, SQLITE_TRANSIENT)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(limit))
            var entries: [Entry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                entries.append(Entry(
                    id: sqlite3_column_int64(statement, 0),
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    directory: Self.text(statement, 2),
                    command: Self.text(statement, 3),
                    output: Self.text(statement, 4),
                    exitCode: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 5),
                    duration: sqlite3_column_double(statement, 6)
                ))
            }
            return entries
        } ?? []
    }

    public var count: Int {
        withStatement("SELECT COUNT(*) FROM entries") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        } ?? 0
    }

    /// Drops entries older than `date`, then the oldest beyond `maxEntries`.
    public func prune(olderThan date: Date, maxEntries: Int) {
        _ = withStatement("DELETE FROM entries WHERE date < ?") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            return sqlite3_step(statement)
        }
        _ = withStatement("DELETE FROM entries WHERE id NOT IN (SELECT id FROM entries ORDER BY date DESC LIMIT ?)") { statement in
            sqlite3_bind_int(statement, 1, Int32(maxEntries))
            return sqlite3_step(statement)
        }
    }

    public func removeAll() {
        sqlite3_exec(db, "DELETE FROM entries; INSERT INTO entries_fts(entries_fts) VALUES('rebuild'); VACUUM;", nil, nil, nil)
    }

    /// `git pu` → `"git"* AND "pu"*`; nil for an empty query.
    static func ftsQuery(_ query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { word in
            "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }
        return words.isEmpty ? nil : words.joined(separator: " AND ")
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer?) -> T) -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return body(statement)
    }
}
