import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(CSQLite)
import CSQLite
#endif

public struct LibrarySearchIndexMetrics: Sendable {
    public var cachedReads = 0
    public var sourceReads = 0
    public var indexedExclusions = 0
    public var recoveries = 0
    public var cacheFailures = 0
}

/// Rebuildable, local search indexes. The original evaluator remains the final
/// authority: the index supplies conservative candidates, never final matches.
public actor PersistentLibrarySearchProvider: LibrarySearchContentProvider {
    private let source: any LibrarySearchContentProvider
    private let directory: URL
    public private(set) var metrics = LibrarySearchIndexMetrics()
    #if canImport(CSQLite)
    private var indexes: [String: SearchIndexDatabase] = [:]
    #endif

    public init(source: any LibrarySearchContentProvider, directory: URL? = nil) {
        self.source = source
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? cacheRoot.appendingPathComponent("org.libronx.mac.rebuild/search-v2", isDirectory: true)
    }
    public static func filename(for resource: LibraryResource) -> String {
        digest(Data((resource.id + "\n" + resource.location.standardizedFileURL.path).utf8)) + ".sqlite"
    }
    public func supports(_ resource: LibraryResource) async -> Bool { await source.supports(resource) }
    public func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
        let prepared = try await source.prepare(resource)
        try await source.verifyUnchanged(resource, prepared: prepared)
        #if canImport(CSQLite)
        do {
            // Synthetic providers without source stamps cannot establish a
            // reusable source identity and deliberately remain uncached.
            if !prepared.sourceStamps.isEmpty {
                indexes[resource.id] = nil
                if indexes.count >= 8, let oldest = indexes.keys.sorted().first { indexes[oldest] = nil }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(Self.filename(for: resource))
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                    throw SearchIndexFailure.storage
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let identity = Self.digest(try encoder.encode(prepared))
                do { indexes[resource.id] = try SearchIndexDatabase(url: url, identity: identity) }
                catch SearchIndexFailure.corrupt {
                    // Quarantine only this generated cache. Never touch the
                    // resource, its normalized reader DB, or personal documents.
                    for suffix in ["", "-wal", "-shm"] {
                        let member = URL(fileURLWithPath: url.path + suffix)
                        if FileManager.default.fileExists(atPath: member.path) {
                            try FileManager.default.moveItem(at: member, to: URL(fileURLWithPath: member.path + ".invalid-" + UUID().uuidString))
                        }
                    }
                    metrics.recoveries += 1
                    indexes[resource.id] = try SearchIndexDatabase(url: url, identity: identity)
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { indexes[resource.id] = nil; metrics.cacheFailures += 1 }
        #endif
        return prepared
    }
    public func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
        try await source.verifyUnchanged(resource, prepared: prepared)
    }
    public func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor,
                     prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
        try await source.verifyUnchanged(resource, prepared: prepared)
        #if canImport(CSQLite)
        if let index = indexes[resource.id] {
            do {
                if let cached = try index.read(article.sectionOrdinal) {
                    try await source.verifyUnchanged(resource, prepared: prepared)
                    metrics.cachedReads += 1
                    return cached
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A damaged record is never served. Stop using this index for
                // this search and rebuild the derivative cache on the next one.
                try? index.invalidate()
                indexes[resource.id] = nil; metrics.recoveries += 1
            }
        }
        #endif
        let decoded = try await source.read(resource, article: article, prepared: prepared)
        try await source.verifyUnchanged(resource, prepared: prepared)
        metrics.sourceReads += 1
        #if canImport(CSQLite)
        if let index = indexes[resource.id] {
            do { try index.write(decoded, ordinal: article.sectionOrdinal) }
            catch is CancellationError { throw CancellationError() }
            catch { indexes[resource.id] = nil; metrics.cacheFailures += 1 }
        }
        #endif
        return decoded
    }
    public func candidates(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource,
                           query: SearchQuery, options: TextSearchOptions, unit: LibrarySearchUnit) async throws -> Set<Int>? {
        try await source.verifyUnchanged(resource, prepared: prepared)
        #if canImport(CSQLite)
        // Verse mode must still inspect anchors, including on non-Bible books,
        // so incompatible verse scopes cannot masquerade as complete no-hits.
        if !prepared.isCompactDirectory, options.maximumEditDistance == 0, unit == .article, !query.expression.requiresVerseContext, query.expression.requiredFields.isEmpty, let index = indexes[resource.id] {
            do {
                if let selected = try index.candidates(query.expression, articles: prepared.articles) {
                    try await source.verifyUnchanged(resource, prepared: prepared)
                    metrics.indexedExclusions += prepared.articles.count - selected.count
                    return selected
                }
            } catch is CancellationError { throw CancellationError() }
            catch { indexes[resource.id] = nil; metrics.cacheFailures += 1 }
        }
        #endif
        return nil
    }
    public func excludedCandidates(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource,
                                   query: SearchQuery, options: TextSearchOptions, unit: LibrarySearchUnit) async throws -> Set<Int>? {
        try await source.verifyUnchanged(resource, prepared: prepared)
        #if canImport(CSQLite)
        if prepared.isCompactDirectory, options.maximumEditDistance == 0, unit == .article,
           !query.expression.requiresVerseContext, query.expression.requiredFields.isEmpty, let index = indexes[resource.id] {
            do {
                if let excluded = try index.excludedCandidates(query.expression, articleCount: prepared.articleCount) {
                    try await source.verifyUnchanged(resource, prepared: prepared)
                    metrics.indexedExclusions += excluded.count
                    return excluded
                }
            } catch is CancellationError { throw CancellationError() }
            catch { indexes[resource.id] = nil; metrics.cacheFailures += 1 }
        }
        #endif
        return nil
    }
    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

#if canImport(CSQLite)
private enum SearchIndexFailure: Error { case storage, corrupt }

/// Connection is confined to its owning provider actor. Schema, SQL and FTS
/// syntax are fixed; article text and query operands are bound parameters.
private final class SearchIndexDatabase {
    private var db: OpaquePointer?
    private let maximumRecordBytes = 64 * 1024 * 1024
    init(url: URL, identity: String) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw SearchIndexFailure.corrupt
        }
        var existing = false
        do {
            sqlite3_busy_timeout(db, 250)
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(maximumRecordBytes))
            sqlite3_progress_handler(db, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            guard try strings("PRAGMA quick_check").first == "ok" else { throw SearchIndexFailure.corrupt }
            let version = try strings("PRAGMA user_version").first
            existing = version != "0"
            if version == "0" {
                try transaction {
                    try execute("CREATE TABLE identity(value TEXT NOT NULL)")
                    try execute("CREATE TABLE articles(ordinal INTEGER PRIMARY KEY, body BLOB NOT NULL, sha256 TEXT NOT NULL, ascii INTEGER NOT NULL, metadata_sha256 TEXT NOT NULL)")
                    // https://www.sqlite.org/fts5.html#the_trigram_tokenizer
                    try execute("CREATE VIRTUAL TABLE terms USING fts5(value, tokenize='trigram case_sensitive 1')")
                    try execute("INSERT INTO identity VALUES(?)", strings: [identity])
                    try execute("PRAGMA user_version=2")
                }
            } else {
                guard version == "2" else { throw SearchIndexFailure.corrupt }
                if try strings("SELECT value FROM identity").first != identity {
                    try transaction {
                        try clear()
                        try execute("INSERT INTO identity VALUES(?)", strings: [identity])
                    }
                }
                try execute("INSERT INTO terms(terms) VALUES('integrity-check')")
                _ = try auditedOrdinals()
            }
        } catch {
            let code = sqlite3_errcode(db)
            sqlite3_close(db); db = nil
            if Task.isCancelled { throw CancellationError() }
            if existing, ![SQLITE_BUSY, SQLITE_LOCKED].contains(code) { throw SearchIndexFailure.corrupt }
            throw error
        }
    }
    deinit { sqlite3_close(db) }
    private func statement(_ sql: String) throws -> OpaquePointer {
        try Task.checkCancellation()
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else {
            if let result { sqlite3_finalize(result) }
            throw failure()
        }
        return result
    }
    private func failure() -> SearchIndexFailure {
        let code = sqlite3_errcode(db)
        return [SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_SCHEMA].contains(code) ? .corrupt : .storage
    }
    private func bind(_ values: [String], _ statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let bytes = value.utf8.count
            guard bytes < maximumRecordBytes,
                  value.withCString({ sqlite3_bind_text(statement, Int32(offset + 1), $0, Int32(bytes), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw failure() }
        }
    }
    private func execute(_ sql: String, strings: [String] = []) throws {
        let s = try statement(sql); defer { sqlite3_finalize(s) }
        try bind(strings, s)
        let status = sqlite3_step(s)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw failure() }
    }
    private func strings(_ sql: String) throws -> [String] {
        let s = try statement(sql); defer { sqlite3_finalize(s) }
        var values: [String] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW, values.count < 2_000_000, let value = sqlite3_column_text(s, 0) else { throw failure() }
            values.append(String(cString: value))
        }
    }
    private func ordinals(_ sql: String, value: String? = nil) throws -> Set<Int> {
        let s = try statement(sql); defer { sqlite3_finalize(s) }
        if let value { try bind([value], s) }
        var values = Set<Int>()
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW, values.count < 2_000_000 else { throw failure() }
            let ordinal = Int(sqlite3_column_int64(s, 0))
            guard ordinal >= 0 else { throw SearchIndexFailure.corrupt }
            values.insert(ordinal)
        }
    }
    private static func metadataHash(ordinal: Int, ascii: Int, bodyHash: String) -> String {
        PersistentLibrarySearchProvider.digest(Data("\(ordinal):\(ascii):\(bodyHash)".utf8))
    }
    private func auditedOrdinals() throws -> (all: Set<Int>, unicode: Set<Int>) {
        let s = try statement("SELECT ordinal,ascii,sha256,metadata_sha256 FROM articles")
        defer { sqlite3_finalize(s) }
        var all = Set<Int>(), unicode = Set<Int>()
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return (all, unicode) }
            guard status == SQLITE_ROW, all.count < 2_000_000,
                  let bodyHash = sqlite3_column_text(s, 2), let checksum = sqlite3_column_text(s, 3) else { throw SearchIndexFailure.corrupt }
            let ordinal = Int(sqlite3_column_int64(s, 0)), ascii = Int(sqlite3_column_int(s, 1))
            guard ordinal >= 0, [0, 1].contains(ascii),
                  Self.metadataHash(ordinal: ordinal, ascii: ascii, bodyHash: String(cString: bodyHash)) == String(cString: checksum),
                  all.insert(ordinal).inserted else { throw SearchIndexFailure.corrupt }
            if ascii == 0 { unicode.insert(ordinal) }
        }
    }
    private func transaction<T>(_ begin: String = "BEGIN IMMEDIATE", _ body: () throws -> T) throws -> T {
        try execute(begin)
        do { let result = try body(); try execute("COMMIT"); return result }
        catch {
            // Cancellation must not suppress rollback and leave a writer lock.
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }
    private func clear() throws {
        try execute("DELETE FROM articles")
        try execute("DELETE FROM terms")
        try execute("DELETE FROM identity")
    }
    func invalidate() throws {
        try transaction { try clear() }
    }
    func read(_ ordinal: Int) throws -> LibrarySearchDecodedArticle? {
        let s = try statement("SELECT body,sha256 FROM articles WHERE ordinal=?"); defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(ordinal))
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        let size = Int(sqlite3_column_bytes(s, 0))
        guard status == SQLITE_ROW, size > 0, size < maximumRecordBytes,
              let bytes = sqlite3_column_blob(s, 0), let rawHash = sqlite3_column_text(s, 1) else { throw SearchIndexFailure.corrupt }
        let data = Data(bytes: bytes, count: size)
        guard PersistentLibrarySearchProvider.digest(data) == String(cString: rawHash) else { throw SearchIndexFailure.corrupt }
        let article = try JSONDecoder().decode(LibrarySearchDecodedArticle.self, from: data)
        try article.fieldDirectory?.validate(in: article.text)
        try TextSearchEngine.validateLexicalBreaks(article.lexicalBreaks, in: article.text)
        return article
    }
    func write(_ article: LibrarySearchDecodedArticle, ordinal: Int) throws {
        let data = try JSONEncoder().encode(article)
        guard data.count < maximumRecordBytes, ordinal >= 0 else { throw SearchIndexFailure.storage }
        let text: String
        if let range = article.searchRange {
            guard range.location >= 0, range.length >= 0, range.location <= article.text.utf16.count,
                  range.length <= article.text.utf16.count - range.location,
                  Range(range.nsRange, in: article.text) != nil else { throw SearchIndexFailure.storage }
            text = (article.text as NSString).substring(with: range.nsRange)
        } else { text = article.text }
        let ascii = text.utf8.allSatisfy { $0 > 0 && $0 < 128 }
        try transaction {
            let s = try statement("INSERT OR REPLACE INTO articles VALUES(?,?,?,?,?)"); defer { sqlite3_finalize(s) }
            sqlite3_bind_int64(s, 1, Int64(ordinal))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            let hash = PersistentLibrarySearchProvider.digest(data)
            _ = hash.withCString { sqlite3_bind_text(s, 3, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_bind_int(s, 4, ascii ? 1 : 0)
            let metadataHash = Self.metadataHash(ordinal: ordinal, ascii: ascii ? 1 : 0, bodyHash: hash)
            _ = metadataHash.withCString { sqlite3_bind_text(s, 5, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
            try execute("DELETE FROM terms WHERE rowid=?", strings: [String(ordinal + 1)])
            try execute("INSERT INTO terms(rowid,value) VALUES(?,?)", strings: [String(ordinal + 1), ascii ? text.lowercased() : ""])
        }
    }
    // Unicode equivalences in NSString and SQLite are not assumed equal.
    // Non-ASCII text, short terms, negation and unindexed articles remain candidates.
    private func possible(_ expression: SearchExpression) throws -> Set<Int>? {
            switch expression {
            case .term(let operand), .phrase(let operand):
                guard operand.text.utf8.count >= 3,
                      operand.text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
                let literal = "\"" + operand.text.lowercased().replacingOccurrences(of: "\"", with: "\"\"") + "\""
                return try ordinals("SELECT rowid-1 FROM terms WHERE terms MATCH ?", value: literal)
            case .conjunction(let lhs, let rhs), .proximity(_, let lhs, let rhs):
                let left = try possible(lhs), right = try possible(rhs)
                if let left, let right { return left.intersection(right) }
                return left ?? right
            case .disjunction(let lhs, let rhs):
                guard let left = try possible(lhs), let right = try possible(rhs) else { return nil }
                return left.union(right)
            case .negation, .field: return nil
            }
    }
    func candidates(_ expression: SearchExpression, articles: [LibrarySearchArticleDescriptor]) throws -> Set<Int>? {
        // All component sets must see one SQLite snapshot. A concurrent writer
        // must not turn an unknown article into an excluded cached article
        // between collecting the FTS hits and the cached-ordinal set.
        return try transaction("BEGIN DEFERRED") {
            guard let hits = try possible(expression) else { return nil }
            let all = Set(articles.map(\.sectionOrdinal))
            let cached = try auditedOrdinals()
            guard cached.all.isSubset(of: all) else { throw SearchIndexFailure.corrupt }
            return all.subtracting(cached.all).union(cached.unicode).union(hits)
        }
    }
    func excludedCandidates(_ expression: SearchExpression, articleCount: Int) throws -> Set<Int>? {
        // Read hits and audited metadata from one snapshot. Only already indexed
        // ASCII articles absent from a conservative hit set can be excluded.
        try transaction("BEGIN DEFERRED") {
            guard let hits = try possible(expression) else { return nil }
            let cached = try auditedOrdinals()
            let indexed = try ordinals("SELECT rowid-1 FROM terms")
            guard (1...2_000_000).contains(articleCount),
                  cached.all.allSatisfy({ (0..<articleCount).contains($0) }),
                  indexed == cached.all, hits.isSubset(of: cached.all) else { throw SearchIndexFailure.corrupt }
            return cached.all.subtracting(cached.unicode).subtracting(hits)
        }
    }
}
#endif
