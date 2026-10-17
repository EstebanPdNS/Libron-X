import Foundation
#if canImport(CSQLite)
import CSQLite
#endif

public struct ESwordEntry: Sendable {
    public var title: String
    public var body: String
    public var reference: String?
    public init(title: String, body: String, reference: String?) { self.title = title; self.body = body; self.reference = reference }
}
public struct ESwordPage: Sendable {
    public var ordinal: Int
    public var entries: [ESwordEntry]
    public var contents: [String]
    public init(ordinal: Int, entries: [ESwordEntry], contents: [String]) { self.ordinal = ordinal; self.entries = entries; self.contents = contents }
}
/// Reads only fixed known schemas. User paths and search text never become SQL.
public enum ESwordResource {
    public static let extensions: Set<String> = ["refi", "dcti", "bblx", "bbli", "lexi", "cmti"]
    #if canImport(CSQLite)
    private final class Database {
        var handle: OpaquePointer?
        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let handle { sqlite3_close(handle) }; handle = nil
                throw LibronError.invalid("e-Sword: unreadable SQLite database")
            }
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 16 * 1024 * 1024)
            _ = try rows("PRAGMA query_only=ON")
            _ = try rows("PRAGMA trusted_schema=OFF")
        }
        deinit { sqlite3_close(handle) }
        func rows(_ sql: String, integers: [Int] = []) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw LibronError.invalid("e-Sword: unsupported or protected schema") }
            defer { sqlite3_finalize(statement) }
            for (i, value) in integers.enumerated() { sqlite3_bind_int64(statement, Int32(i + 1), Int64(value)) }
            var rows: [[String]] = [], bytes = 0
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw LibronError.invalid("e-Sword: invalid database") }
                guard rows.count < 100_000 else { throw LibronError.invalid("e-Sword: row limit exceeded") }
                var row: [String] = []
                for i in 0..<sqlite3_column_count(statement) {
                    // BLOB bodies are encrypted/unsupported; do not import gibberish.
                    guard sqlite3_column_type(statement, i) != SQLITE_BLOB else { throw LibronError.invalid("e-Sword: encrypted or unsupported content") }
                    let value = sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
                    bytes += value.utf8.count
                    guard bytes < 64 * 1024 * 1024 else { throw LibronError.invalid("e-Sword: page size limit exceeded") }
                    row.append(value)
                }
                rows.append(row)
            }
            return rows
        }
        func kind() throws -> String {
            let names = Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap(\.first))
            guard names.contains("Details") else { throw LibronError.invalid("e-Sword: missing Details") }
            for name in ["Bible", "Dictionary", "Lexicon", "Reference", "VerseCommentary"] where names.contains(name) { return name }
            throw LibronError.invalid("e-Sword: unsupported content tables")
        }
    }
    public static func inspect(_ url: URL) throws -> LibraryResource {
        let db = try Database(url), kind = try db.kind()
        guard let detail = try db.rows("SELECT Title, Abbreviation, Information FROM Details LIMIT 1").first, detail.count == 3,
              !detail[0].isEmpty else { throw LibronError.invalid("e-Sword: missing title") }
        var m = LibronMetadata(title: detail[0], origin: "e-Sword")
        m.originalTitle = detail[0]; m.abbreviation = detail[1]; m.originalInformation = detail[2]
        switch kind {
        case "Bible": m.resourceType = "Biblia"; m.category = "Biblias y texto bíblico"
        case "Dictionary": m.resourceType = "Diccionario o enciclopedia"; m.category = "Referencia general"
        case "Lexicon": m.resourceType = "Léxico"; m.category = "Lenguas bíblicas"
        case "VerseCommentary": m.resourceType = "Comentario bíblico"; m.category = "Estudios bíblicos"
        default: m.resourceType = "Monografía"; m.category = "Referencia general"
        }
        let foldedTitle = m.title.folding(options: [.caseInsensitive,.diacriticInsensitive], locale: Locale(identifier: "es"))
        if kind == "Dictionary", foldedTitle.contains("compendio") {
            m.resourceType = "Manual o curso"; m.category = "Estudios bíblicos"
        } else if kind == "Dictionary", foldedTitle.contains("biblia textual") {
            m.resourceType = "Monografía"; m.category = "Estudios bíblicos"
        }
        m.evidence = [.init(field: "title", value: m.title, source: "embedded:Details.Title"),
                      .init(field: "resourceType", value: m.resourceType, source: "embedded:sqlite-schema")]
        m.pendingFields = ["authors", "year", "publisher", "languages", "edition"]
        // Probe actual content, separately from metadata, to reject protected bodies.
        _ = try page(url, ordinal: 0)
        return LibraryResource(location: url, title: m.title, byteCount: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
            format: .eSwordSQLite, support: .metadataOnly, provenance: .libronixMetadata, libron: m)
    }
    public static let bookCodes = ["Ge","Ex","Le","Nu","De","Jos","Jdg","Ru","1Sa","2Sa","1Ki","2Ki","1Ch","2Ch","Ezr","Ne","Es","Job","Ps","Pr","Ec","So","Isa","Jer","La","Eze","Da","Ho","Joe","Am","Ob","Jon","Mic","Na","Hab","Zep","Hag","Zec","Mal","Mt","Mr","Lu","Joh","Ac","Ro","1Co","2Co","Ga","Eph","Php","Col","1Th","2Th","1Ti","2Ti","Tit","Phm","Heb","Jas","1Pe","2Pe","1Jo","2Jo","3Jo","Jude","Re"]
    private static func reference(_ book: Int, _ chapter: Int, _ verse: Int? = nil) -> String {
        let code = (1...bookCodes.count).contains(book) ? bookCodes[book - 1] : "Book \(book)"
        return code + " \(chapter)" + (verse.map { ":\($0)" } ?? "")
    }
    public static func page(_ url: URL, ordinal: Int, reference query: String? = nil) throws -> ESwordPage {
        let db = try Database(url), kind = try db.kind()
        if kind == "Bible" {
            let chapters = try db.rows("SELECT DISTINCT Book,Chapter FROM Bible ORDER BY Book,Chapter").compactMap { row -> (Int, Int)? in
                guard row.count == 2, let b = Int(row[0]), let c = Int(row[1]) else { return nil }; return (b,c)
            }
            var index = ordinal
            if let query {
                guard let parsed = LegacyPassageQuery.sourceReference(query),
                      let match = chapters.firstIndex(where: { pair in
                          guard let candidate = LegacyPassageQuery.sourceReference(reference(pair.0, pair.1, 1)) else { return false }
                          return candidate.book == parsed.book && candidate.chapter == parsed.chapter
                      }) else { throw LibronError.invalid("e-Sword: reference not found") }
                index = match
            }
            guard chapters.indices.contains(index) else { throw LibronError.invalid("e-Sword: chapter not found") }
            let chapter = chapters[index]
            let verses = try db.rows("SELECT Verse,Scripture FROM Bible WHERE Book=? AND Chapter=? ORDER BY Verse", integers: [chapter.0, chapter.1])
            return ESwordPage(ordinal: index, entries: verses.map { .init(title: $0[0], body: $0[1], reference: reference(chapter.0, chapter.1, Int($0[0]))) },
                              contents: chapters.map { reference($0.0, $0.1) })
        }
        let directory: [[String]], bodySQL: String
        switch kind {
        case "Dictionary": directory = try db.rows("SELECT rowid,Topic FROM Dictionary ORDER BY rowid"); bodySQL = "SELECT Definition FROM Dictionary WHERE rowid=?"
        case "Lexicon": directory = try db.rows("SELECT rowid,Topic FROM Lexicon ORDER BY rowid"); bodySQL = "SELECT Definition FROM Lexicon WHERE rowid=?"
        case "Reference": directory = try db.rows("SELECT rowid,Chapter FROM Reference ORDER BY rowid"); bodySQL = "SELECT Content FROM Reference WHERE rowid=?"
        default:
            // Retain book/chapter introductions, not only verse commentaries.
            let book = try db.rows("SELECT rowid,Book FROM BookCommentary ORDER BY Book").map { ["B" + $0[0], "Book " + $0[1]] }
            let chapters = try db.rows("SELECT rowid,Book,Chapter FROM ChapterCommentary ORDER BY Book,Chapter").map { ["C" + $0[0], reference(Int($0[1]) ?? 0, Int($0[2]) ?? 0)] }
            let verses = try db.rows("SELECT rowid,Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd FROM VerseCommentary ORDER BY Book,ChapterBegin,VerseBegin").map { row in
                ["V" + row[0], reference(Int(row[1]) ?? 0, Int(row[2]) ?? 0, Int(row[3]) ?? 0) + "–" + row[4] + ":" + row[5]]
            }
            directory = book + chapters + verses; bodySQL = ""
        }
        guard directory.indices.contains(ordinal) else { throw LibronError.invalid("e-Sword: entry not found") }
        let row = directory[ordinal], body: String
        if kind == "VerseCommentary" {
            let table = row[0].first == "B" ? "BookCommentary" : row[0].first == "C" ? "ChapterCommentary" : "VerseCommentary"
            body = try db.rows("SELECT Comments FROM \(table) WHERE rowid=?", integers: [Int(row[0].dropFirst()) ?? -1]).first?.first ?? ""
        } else { body = try db.rows(bodySQL, integers: [Int(row[0]) ?? -1]).first?.first ?? "" }
        return ESwordPage(ordinal: ordinal, entries: [.init(title: row[1], body: body, reference: nil)], contents: directory.map { $0[1] })
    }
    #else
    public static func inspect(_ url: URL) throws -> LibraryResource { throw LibronError.invalid("SQLite importer unavailable on this platform") }
    public static func page(_ url: URL, ordinal: Int, reference: String? = nil) throws -> ESwordPage { throw LibronError.invalid("SQLite reader unavailable on this platform") }
    #endif
}
