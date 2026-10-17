import Foundation
import CLibronxCompression
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(CSQLite)
import CSQLite

/// Versioned normalized content. Statements are fixed; user text is bound.
/// Connections belong to the caller's actor, never shared concurrently.
public final class LibronNativeDatabase {
    private var db: OpaquePointer?
    private let limit = 64 * 1024 * 1024
    public init(_ url: URL, create: Bool = false, edit: Bool = false) throws {
        let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : edit ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw LibronError.invalid("Cannot open normalized content")
        }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(limit))
        try execute("PRAGMA trusted_schema=OFF")
        if create {
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA user_version=1")
            try execute("CREATE TABLE values_v1(key TEXT PRIMARY KEY,body BLOB NOT NULL,size INTEGER NOT NULL,sha256 TEXT NOT NULL) WITHOUT ROWID")
            try execute("CREATE TABLE bible_v1(book TEXT,chapter INTEGER,verse INTEGER,ordinal INTEGER,offset INTEGER,reference TEXT,PRIMARY KEY(book,chapter,verse,ordinal,offset)) WITHOUT ROWID")
            try execute("CREATE TABLE words_v1(key TEXT,ordinal INTEGER,headword TEXT,PRIMARY KEY(key,ordinal)) WITHOUT ROWID")
            try execute("BEGIN IMMEDIATE")
        }
        if edit && !create { try execute("BEGIN IMMEDIATE") }
        guard try rows("PRAGMA user_version").first?.first == "1" else { throw LibronError.invalid("Unsupported normalized content version") }
    }
    deinit { sqlite3_close(db) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw LibronError.invalid("Invalid normalized content schema") }
        return statement
    }
    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func execute(_ sql: String, values: [String] = []) throws {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        for (i,value) in values.enumerated() { bind(value, Int32(i+1), statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw LibronError.invalid("Normalized content write failed") }
    }
    private func rows(_ sql: String, values: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        for (i,value) in values.enumerated() { bind(value, Int32(i+1), statement) }
        var rows: [[String]] = [], total = 0
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW, rows.count < 2_000_000 else { throw LibronError.invalid("Invalid normalized index") }
            let row = (0..<sqlite3_column_count(statement)).map { column in sqlite3_column_text(statement,column).map { String(cString:$0) } ?? "" }
            total += row.reduce(0) { $0 + $1.utf8.count }
            guard total < limit else { throw LibronError.invalid("Normalized index limit exceeded") }
            rows.append(row)
        }
    }
    public func put(_ key: String, data: Data) throws {
        guard !data.isEmpty, data.count < limit else { throw LibronError.invalid("Normalized record limit exceeded") }
        var encoded = Data(count: data.count + data.count / 1000 + 128), written = 0
        let capacity = encoded.count
        let status = data.withUnsafeBytes { input in encoded.withUnsafeMutableBytes { output in
            libronx_deflate_zlib(input.bindMemory(to: UInt8.self).baseAddress, data.count, output.bindMemory(to: UInt8.self).baseAddress, capacity, &written)
        } }
        guard status == 0 else { throw LibronError.invalid("Normalized content compression failed") }
        encoded.count = written
        let statement = try prepare("INSERT OR REPLACE INTO values_v1 VALUES(?,?,?,?)"); defer { sqlite3_finalize(statement) }
        bind(key,1,statement)
        _ = encoded.withUnsafeBytes { sqlite3_bind_blob(statement,2,$0.baseAddress,Int32(encoded.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
        sqlite3_bind_int64(statement,3,Int64(data.count));bind(Self.hash(data),4,statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LibronError.invalid("Normalized record write failed") }
    }
    public func get(_ key: String) throws -> Data? {
        let statement = try prepare("SELECT body,size,sha256 FROM values_v1 WHERE key=?"); defer { sqlite3_finalize(statement) };bind(key,1,statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw LibronError.invalid("Normalized record read failed") }
        let size = Int(sqlite3_column_int64(statement,1)), stored = Int(sqlite3_column_bytes(statement,0))
        guard size > 0, size < limit, stored > 0, stored < limit, let source = sqlite3_column_blob(statement,0),
              let hash = sqlite3_column_text(statement,2) else { throw LibronError.invalid("Invalid normalized record") }
        let expected = String(cString:hash), encoded = Data(bytes:source,count:stored)
        var decoded = Data(count:size), written = 0
        let result = encoded.withUnsafeBytes { input in decoded.withUnsafeMutableBytes { output in
            libronx_inflate_zlib(input.bindMemory(to:UInt8.self).baseAddress,stored,output.bindMemory(to:UInt8.self).baseAddress,size,&written)
        } }
        guard result == 0, written == size, Self.hash(decoded) == expected else { throw LibronError.invalid("Normalized record checksum mismatch") }
        return decoded
    }
    public func clearReferences() throws { try execute("DELETE FROM bible_v1") }
    public func add(reference: String, ordinal: Int, offset: Int) throws {
        guard let q = LegacyPassageQuery.sourceReference(reference), ordinal >= 0, offset >= 0 else { return }
        try execute("INSERT OR IGNORE INTO bible_v1 VALUES(?,?,?,?,?,?)",values:[q.sourceBookKey,String(q.chapter),String(q.verse),String(ordinal),String(offset),q.displayReference])
    }
    public func resolve(_ reference: String) throws -> (ordinal: Int, offset: Int, reference: String)? {
        guard let q = LegacyPassageQuery.navigationInput(reference), let row = try rows("SELECT ordinal,offset,reference FROM bible_v1 WHERE book=? AND chapter=? AND verse=? ORDER BY ordinal,offset LIMIT 1",values:[q.sourceBookKey,String(q.chapter),String(q.verse)]).first,
              row.count == 3, let ordinal = Int(row[0]), let offset = Int(row[1]) else { return nil }
        return (ordinal,offset,row[2])
    }
    public func chapterReferences() throws -> [String] {
        try rows("SELECT book,chapter,MIN(verse) FROM bible_v1 GROUP BY book,chapter ORDER BY MIN(ordinal),MIN(offset)").compactMap { row in
            guard row.count == 3 else { return nil }; return row[0]+" "+row[1]+":"+row[2]
        }
    }
    public func add(word: LibronDictionaryEntry) throws {
        for key in LibronDictionaryIndex.aliases(word.headword) {
            try execute("INSERT OR IGNORE INTO words_v1 VALUES(?,?,?)",values:[key,String(word.ordinal),word.headword])
        }
    }
    public func match(_ word: String) throws -> LibronDictionaryEntry? {
        guard let row = try rows("SELECT headword,ordinal FROM words_v1 WHERE key=? ORDER BY ordinal LIMIT 1",values:[LibronDictionaryIndex.key(word)]).first,
              let ordinal = Int(row[1]) else { return nil }
        return .init(headword:row[0],ordinal:ordinal)
    }
    public func finish() throws {
        try execute("COMMIT")
        guard try rows("PRAGMA integrity_check").first?.first == "ok" else { throw LibronError.invalid("Normalized database integrity failure") }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}
#endif
