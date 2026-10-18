import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
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
    public static let extensions: Set<String> = ["refi", "dcti", "bblx", "bbli", "lexi", "cmti", "devi"]
    #if canImport(CSQLite)
    private final class Database {
        var handle: OpaquePointer?
        var directories: [String:[[String]]] = [:]
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
            let directory = integers.isEmpty && (sql.hasPrefix("SELECT rowid,") || sql.hasPrefix("SELECT DISTINCT Book,Chapter"))
            if directory, let cached = directories[sql] { return cached }

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
            if directory { directories[sql] = rows }
            return rows
        }
        func kind() throws -> String {
            let names = Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap(\.first))
            guard names.contains("Details") else { throw LibronError.invalid("e-Sword: missing Details") }
            for name in ["Bible", "Dictionary", "Lexicon", "Reference", "VerseCommentary", "Devotional"] where names.contains(name) { return name }
            throw LibronError.invalid("e-Sword: unsupported content tables")
        }
    }
    public static func inspect(_ url: URL) throws -> LibraryResource {
        let db = try Database(url), kind = try db.kind()
        let columns = Set(try db.rows("PRAGMA table_info(Details)").compactMap { $0.count > 1 ? $0[1].lowercased() : nil })
        let detailsSQL: String
        if columns.contains("title"), columns.contains("information") { detailsSQL = "SELECT Title, Abbreviation, Information FROM Details LIMIT 1" }
        else if columns.contains("description"), columns.contains("comments") { detailsSQL = "SELECT Description, Abbreviation, Comments FROM Details LIMIT 1" }
        else { throw LibronError.invalid("e-Sword: unsupported Details schema") }
        guard let detail = try db.rows(detailsSQL).first, detail.count == 3,
              !detail[0].isEmpty else { throw LibronError.invalid("e-Sword: missing title") }
        var m = LibronMetadata(title: detail[0], origin: "e-Sword")
        m.originalTitle = detail[0]; m.abbreviation = detail[1]; m.originalInformation = detail[2]
        switch kind {
        case "Bible": m.resourceType = "Biblia"; m.category = "Biblias y texto bíblico"
        case "Dictionary": m.resourceType = "Diccionario o enciclopedia"; m.category = "Referencia general"
        case "Lexicon": m.resourceType = "Léxico"; m.category = "Lenguas bíblicas"
        case "Devotional": m.resourceType = "Devocional"; m.category = "Vida cristiana y espiritualidad"
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
        let sample = try page(url, ordinal: 0)
        var info = detail[2].replacingOccurrences(of:#"(?i)<br\s*/?>|</(?:p|div|li|h[1-6])\s*>"#,with:"\n",options:.regularExpression)
            .replacingOccurrences(of:#"<[^>]*>"#,with:" ",options:.regularExpression)
        let entityPattern = try NSRegularExpression(pattern:#"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        for match in entityPattern.matches(in:info,range:NSRange(info.startIndex...,in:info)).reversed() {
            guard let range = Range(match.range(at:1),in:info), let full = Range(match.range,in:info) else { continue }
            let number = String(info[range]); let value = number.hasPrefix("x") ? UInt32(number.dropFirst(),radix:16) : UInt32(number)
            if let value, let scalar = UnicodeScalar(value) { info.replaceSubrange(full,with:String(scalar)) }
        }
        for (entity,value) in ["&nbsp;":" ","&amp;":"&","&quot;":"\"","&apos;":"'","&copy;":"©","&aacute;":"á","&eacute;":"é","&iacute;":"í","&oacute;":"ó","&uacute;":"ú","&ntilde;":"ñ"] { info = info.replacingOccurrences(of:entity,with:value,options:.caseInsensitive) }
        info = ImportFormattingPipeline.repairLegacyCharacters(info).text

        func declared(_ labels: String) -> String? {
            let pattern = "(?im)(?:^|[\\r\\n])\\s*(?:"+labels+")\\s*[:=]\\s*([^\\r\\n]{1,180})"
            guard let expression = try? NSRegularExpression(pattern:pattern),
                  let match = expression.firstMatch(in:info,range:NSRange(info.startIndex...,in:info)),
                  let range = Range(match.range(at:1),in:info) else { return nil }
            return String(info[range]).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        for (field,value) in [("authors",declared("Authors?|Autor|Autores")),("publisher",declared("Publisher|Editorial")),("year",declared("Year|Año|Ano")),("edition",declared("Edition|Edición|Edicao|Edição"))] {
            guard let value else { continue }
            if field == "authors" { m.authors = [value] }
            if field == "publisher" { m.publisher = value }
            if field == "edition" { m.edition = value }
            if field == "year", value.range(of:#"^\d{4}$"#,options:.regularExpression) != nil { m.year = value }
            m.evidence.append(.init(field:field,value:value,source:"embedded:Details.Information"))
        }
        if kind == "Bible" {
            let title = m.title.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            let labels = [("spanish","es"),("espanol","es"),("portuguese","pt"),("portugues","pt"),("english","en"),("italian","it"),("hebrew","he"),("hebreo","he"),("greek","grc"),("griego","grc")]
            var declared: [String] = []
            for (label,code) in labels where title.range(of:"\\b"+label+"\\b",options:.regularExpression) != nil { if !declared.contains(code) { declared.append(code) } }
            if title.trimmingCharacters(in:.whitespacesAndNewlines) == "lxx" { declared = ["grc"] }
            if !declared.isEmpty {
                m.languages = declared
                m.evidence.append(.init(field:"languages",value:declared.joined(separator:","),source:"embedded:Details.Title:language",status:"inferred"))
            }
        }
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        let text = sample.entries.map(\.body).joined(separator:" ").replacingOccurrences(of:#"<[^>]*>"#,with:" ",options:.regularExpression)
        recognizer.processString(String(text.prefix(30000)))
        if m.languages.isEmpty, let language = recognizer.dominantLanguage, (recognizer.languageHypotheses(withMaximum:1)[language] ?? 0) >= 0.7 {
            m.languages = [language.rawValue]
            m.evidence.append(.init(field:"languages",value:language.rawValue,source:"native-language-recognition:body-sample",status:"inferred"))
        }
        #endif
        m.pendingFields = ["authors":!m.authors.isEmpty,"year":m.year != nil,"publisher":m.publisher != nil,"languages":!m.languages.isEmpty,"edition":m.edition != nil].filter { !$0.value }.keys.sorted()

        return LibraryResource(location: url, title: m.title, author: m.authors.first, languages: m.languages, byteCount: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
            format: .eSwordSQLite, support: .metadataOnly, provenance: .libronixMetadata, libron: m)
    }
    public static func audit(_ url: URL) throws -> ImportFormattingAudit {
        let db = try Database(url), kind = try db.kind()
        let definitions: [(String, String)]
        switch kind {
        case "Bible": definitions = [("Bible", "Scripture")]
        case "Dictionary": definitions = [("Dictionary", "Definition")]
        case "Lexicon": definitions = [("Lexicon", "Definition")]
        case "Reference": definitions = [("Reference", "Content")]
        case "Devotional": definitions = [("Devotional", "Devotion")]
        default:
            let tables = Set(try db.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap(\.first))
            definitions = ["BookCommentary", "ChapterCommentary", "VerseCommentary"].filter { tables.contains($0) }.map { ($0, "Comments") }
        }
        var report = ImportFormattingAudit()
        for (table, column) in definitions {
            var offset = 0
            while true {
                try Task.checkCancellation()
                let rows = try db.rows("SELECT \(column) FROM \(table) ORDER BY rowid LIMIT 100 OFFSET ?", integers: [offset])
                if rows.isEmpty { break }
                for row in rows { report.record(row.first ?? "", ordinal: report.entries) }
                offset += rows.count
            }
        }
        return report
    }
    public static let bookCodes = ["Ge","Ex","Le","Nu","De","Jos","Jdg","Ru","1Sa","2Sa","1Ki","2Ki","1Ch","2Ch","Ezr","Ne","Es","Job","Ps","Pr","Ec","So","Isa","Jer","La","Eze","Da","Ho","Joe","Am","Ob","Jon","Mic","Na","Hab","Zep","Hag","Zec","Mal","Mt","Mr","Lu","Joh","Ac","Ro","1Co","2Co","Ga","Eph","Php","Col","1Th","2Th","1Ti","2Ti","Tit","Phm","Heb","Jas","1Pe","2Pe","1Jo","2Jo","3Jo","Jude","Re","Tob","Jdt","Wis","Sir","Bar","1Ma","2Ma","1Esd","2Esd"]
    private static func reference(_ book: Int, _ chapter: Int, _ verse: Int? = nil) -> String {
        let code = (1...bookCodes.count).contains(book) ? bookCodes[book - 1] : book == 78 ? "PrMan" : "Book \(book)"
        return code + " \(chapter)" + (verse.map { ":\($0)" } ?? "")
    }
    /// Resolve a typed Bible key against fixed SQLite schemas. Commentary
    /// ranges are source rows, never inferred from display titles or body text.
    public static func referenceOrdinal(_ url: URL, reference query: String, endReference: String? = nil) throws -> Int? {
        guard let first = LegacyPassageQuery.sourceReference(query),
              let last = LegacyPassageQuery.sourceReference(endReference ?? query),
              first.sourceBookKey == last.sourceBookKey,
              (first.chapter, first.verse) <= (last.chapter, last.verse) else { return nil }
        let db = try Database(url), kind = try db.kind()
        func isBook(_ number: Int) -> Bool {
            LegacyPassageQuery.sourceReference(reference(number, 1, 1))?.sourceBookKey == first.sourceBookKey
        }
        if kind == "Bible" {
            let chapters = try db.rows("SELECT DISTINCT Book,Chapter FROM Bible ORDER BY Book,Chapter")
            for (index, row) in chapters.enumerated() {
                try Task.checkCancellation()
                guard row.count == 2, let book = Int(row[0]), let chapter = Int(row[1]) else { throw LibronError.invalid("Invalid Bible reference directory") }
                if isBook(book), chapter == first.chapter,
                   try !db.rows("SELECT Verse FROM Bible WHERE Book=? AND Chapter=? AND Verse=?", integers:[book,chapter,first.verse]).isEmpty { return index }
            }
            return nil
        }
        guard kind == "VerseCommentary" else { return nil }
        let books = try db.rows("SELECT rowid,Book FROM BookCommentary ORDER BY Book,rowid")
        let chapters = try db.rows("SELECT rowid,Book,Chapter FROM ChapterCommentary ORDER BY Book,Chapter,rowid")
        let verses = try db.rows("SELECT rowid,Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd FROM VerseCommentary ORDER BY Book,ChapterBegin,VerseBegin,rowid")
        var best: (ordinal: Int, span: Int)?
        for (index, row) in verses.enumerated() {
            try Task.checkCancellation()
            guard row.count == 6, let book = Int(row[1]), let a = Int(row[2]), let b = Int(row[3]), let c = Int(row[4]), let d = Int(row[5]),
                  a > 0, b > 0, c > 0, d > 0, a <= 1_000_000, c <= 1_000_000, b <= 1_000_000, d <= 1_000_000,
                  (a,b) <= (c,d) else { throw LibronError.invalid("Invalid commentary reference directory") }
            if isBook(book), (a,b) <= (first.chapter,first.verse), (last.chapter,last.verse) <= (c,d) {
                let span = (c-a) * 1_000_001 + d-b
                if best == nil || span < best!.span { best = (books.count + chapters.count + index,span) }
            }
        }
        if let best { return best.ordinal }
        for (index,row) in chapters.enumerated() {
            guard row.count == 3, let book = Int(row[1]), let chapter = Int(row[2]) else { throw LibronError.invalid("Invalid commentary chapter directory") }
            if isBook(book), chapter == first.chapter, chapter == last.chapter { return books.count + index }
        }
        for (index,row) in books.enumerated() {
            guard row.count == 2, let book = Int(row[1]) else { throw LibronError.invalid("Invalid commentary book directory") }
            if isBook(book) { return index }
        }
        return nil
    }
    public static func page(_ url: URL, ordinal: Int, reference query: String? = nil) throws -> ESwordPage {
        try page(Database(url),ordinal:ordinal,reference:query)
    }
    /// A converter-owned connection reuses immutable directories across all pages.
    public final class SequentialReader {
        private let database: Database
        public init(_ url: URL) throws { database = try Database(url) }
        public func page(_ ordinal: Int) throws -> ESwordPage { try ESwordResource.page(database,ordinal:ordinal) }
    }
    public static func searchTitles(_ url: URL) throws -> [Int: String] {
        let db = try Database(url), kind = try db.kind()
        let sql: String
        switch kind {
        case "Dictionary": sql = "SELECT rowid,Topic FROM Dictionary ORDER BY rowid"
        case "Lexicon": sql = "SELECT rowid,Topic FROM Lexicon ORDER BY rowid"
        case "Reference": sql = "SELECT rowid,Chapter FROM Reference ORDER BY rowid"
        default: return [:] // Bible/commentary/date labels are generated navigation.
        }
        let rows = try db.rows(sql)
        return Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap { index, row in
            row.count == 2 ? (index, row[1]) : nil
        })
    }
    private static func page(_ db: Database, ordinal: Int, reference query: String? = nil) throws -> ESwordPage {
        let kind = try db.kind()
        if kind == "Bible" {
            let chapters = try db.rows("SELECT DISTINCT Book,Chapter FROM Bible ORDER BY Book,Chapter").compactMap { row -> (Int, Int)? in
                guard row.count == 2, let b = Int(row[0]), let c = Int(row[1]) else { return nil }; return (b,c)
            }
            var index = ordinal
            if let query {
                guard let parsed = LegacyPassageQuery.sourceReference(query),
                      let match = chapters.firstIndex(where: { pair in
                          guard let candidate = LegacyPassageQuery.sourceReference(reference(pair.0, pair.1, 1)) else { return false }
                          return candidate.sourceBookKey == parsed.sourceBookKey && candidate.chapter == parsed.chapter
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
        case "Devotional": directory = try db.rows("SELECT rowid,Month,Day FROM Devotional ORDER BY Month,Day").map { [$0[0],$0[1]+"/"+$0[2]] }; bodySQL = "SELECT Devotion FROM Devotional WHERE rowid=?"
        case "Reference": directory = try db.rows("SELECT rowid,Chapter FROM Reference ORDER BY rowid"); bodySQL = "SELECT Content FROM Reference WHERE rowid=?"
        default:
            // Retain book/chapter introductions, not only verse commentaries.
            let book = try db.rows("SELECT rowid,Book FROM BookCommentary ORDER BY Book,rowid").map { ["B" + $0[0], "Book " + $0[1]] }
            let chapters = try db.rows("SELECT rowid,Book,Chapter FROM ChapterCommentary ORDER BY Book,Chapter,rowid").map { ["C" + $0[0], reference(Int($0[1]) ?? 0, Int($0[2]) ?? 0)] }
            let verses = try db.rows("SELECT rowid,Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd FROM VerseCommentary ORDER BY Book,ChapterBegin,VerseBegin,rowid").map { row in
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
    public static func referenceOrdinal(_ url: URL, reference: String, endReference: String? = nil) throws -> Int? { throw LibronError.invalid("SQLite reader unavailable on this platform") }
    public static func audit(_ url: URL) throws -> ImportFormattingAudit { throw LibronError.invalid("SQLite importer unavailable on this platform") }
    public static func inspect(_ url: URL) throws -> LibraryResource { throw LibronError.invalid("SQLite importer unavailable on this platform") }
    public static func page(_ url: URL, ordinal: Int, reference: String? = nil) throws -> ESwordPage { throw LibronError.invalid("SQLite reader unavailable on this platform") }
    public static func searchTitles(_ url: URL) throws -> [Int: String] { throw LibronError.invalid("SQLite reader unavailable on this platform") }
    #endif
}
