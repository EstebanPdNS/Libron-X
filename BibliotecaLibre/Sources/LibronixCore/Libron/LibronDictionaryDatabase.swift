import Foundation
#if canImport(CSQLite)
import CSQLite
#endif

/// Native, read-only .libron word storage. Text is plain Unicode, never HTML.
public enum LibronDictionaryDatabase {
    public struct Page: Sendable {
        public var ordinal: Int
        public var headword: String
        public var body: String
        public var count: Int
    }
#if canImport(CSQLite)
    private final class Database {
        private var handle: OpaquePointer?
        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let handle { sqlite3_close(handle) }; handle = nil
                throw LibronError.invalid("Unreadable .libron dictionary")
            }
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 4 * 1024 * 1024)
            _ = try rows("PRAGMA trusted_schema=OFF")
            guard try rows("PRAGMA user_version").first?.first == "1" else { throw LibronError.invalid("Unsupported .libron dictionary schema") }
        }
        deinit { sqlite3_close(handle) }
        func rows(_ sql: String, integer: Int? = nil, text: String? = nil) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw LibronError.invalid("Invalid .libron dictionary schema") }
            defer { sqlite3_finalize(statement) }
            if let integer { sqlite3_bind_int64(statement, 1, Int64(integer)) }
            if let text { _ = text.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
            var result: [[String]] = [], bytes = 0
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW, result.count < 2_000_000 else { throw LibronError.invalid("Invalid .libron dictionary data") }
                var row: [String] = []
                for column in 0..<sqlite3_column_count(statement) {
                    guard sqlite3_column_type(statement, column) != SQLITE_BLOB else { throw LibronError.invalid("Invalid .libron dictionary text") }
                    let value = sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                    bytes += value.utf8.count
                    guard bytes < 64 * 1024 * 1024 else { throw LibronError.invalid("Dictionary result exceeds limit") }
                    row.append(value)
                }
                result.append(row)
            }
        }
    }
    public static func count(_ url: URL) throws -> Int {
        guard let value = try Database(url).rows("SELECT COUNT(*) FROM entries").first?.first.flatMap(Int.init), value > 0, value <= 2_000_000 else { throw LibronError.invalid("Invalid dictionary entry count") }
        return value
    }
    public static func entries(_ url: URL) throws -> [LibronDictionaryEntry] {
        try Database(url).rows("SELECT headword,ordinal FROM entries ORDER BY ordinal").map { row in
            guard row.count == 2, let ordinal = Int(row[1]), ordinal >= 0 else { throw LibronError.invalid("Invalid dictionary entry") }
            return .init(headword: row[0], ordinal: ordinal)
        }
    }
    public static func match(_ word: String, at url: URL) throws -> LibronDictionaryEntry? {
        let rows = try Database(url).rows("SELECT e.headword,e.ordinal FROM lookup l JOIN entries e ON e.ordinal=l.ordinal WHERE l.key=? ORDER BY e.ordinal LIMIT 1", text: LibronDictionaryIndex.key(word))
        guard let row = rows.first, row.count == 2, let ordinal = Int(row[1]) else { return nil }
        return .init(headword: row[0], ordinal: ordinal)
    }
    public static func page(_ url: URL, ordinal: Int) throws -> Page {
        let count = try count(url)
        return try page(url, ordinal: ordinal, verifiedCount: count)
    }
    /// Reuse a count obtained from the same unchanged database during a search.
    /// The caller must verify the source has not changed since obtaining it.
    public static func page(_ url: URL, ordinal: Int, verifiedCount count: Int) throws -> Page {
        guard (1...2_000_000).contains(count) else { throw LibronError.invalid("Invalid dictionary entry count") }
        guard (0..<count).contains(ordinal), let row = try Database(url).rows("SELECT headword,body FROM entries WHERE ordinal=? LIMIT 1", integer: ordinal).first,
              row.count == 2, !row[1].isEmpty else { throw LibronError.invalid("Dictionary entry not found") }
        return .init(ordinal: ordinal, headword: row[0], body: row[1], count: count)
    }
#else
    public static func count(_ url: URL) throws -> Int { throw LibronError.invalid("SQLite is unavailable") }
    public static func entries(_ url: URL) throws -> [LibronDictionaryEntry] { throw LibronError.invalid("SQLite is unavailable") }
    public static func match(_ word: String, at url: URL) throws -> LibronDictionaryEntry? { throw LibronError.invalid("SQLite is unavailable") }
    public static func page(_ url: URL, ordinal: Int) throws -> Page { throw LibronError.invalid("SQLite is unavailable") }
    public static func page(_ url: URL, ordinal: Int, verifiedCount: Int) throws -> Page { throw LibronError.invalid("SQLite is unavailable") }
#endif
}
