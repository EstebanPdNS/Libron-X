import Foundation
#if canImport(CSQLite)
import CSQLite
#endif

/// Read-only structural check of a generated search cache. A missing cache is
/// normal: the search provider builds caches on demand.
public enum LibrarySearchIndexHealth: Sendable, Equatable {
    case absent, healthy, damaged, unavailable

    public static func inspect(resource: LibraryResource, directory: URL? = nil, seconds: TimeInterval = 1) -> Self {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = directory ?? cacheRoot.appendingPathComponent("org.libronx.mac.rebuild/search-v2", isDirectory: true)
        let url = directory.appendingPathComponent(PersistentLibrarySearchProvider.filename(for: resource))
        return inspectDatabase(url, version: "2", tables: "'identity','articles','terms'", seconds: seconds)
    }

    public static func inspectNormalized(at url: URL, seconds: TimeInterval = 1) -> Self {
        inspectDatabase(url, version: "1", tables: "'values_v1','bible_v1','words_v1'", seconds: seconds)
    }

    private static func inspectDatabase(_ url: URL, version expectedVersion: String, tables: String, seconds: TimeInterval) -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        #if canImport(CSQLite)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return .unavailable }
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard opened == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return .unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        let deadline = Date().addingTimeInterval(max(0.01, min(seconds, 5)))
        return withUnsafePointer(to: deadline) { pointer in
            sqlite3_progress_handler(db, 1000, { raw in
                guard let raw else { return 1 }
                return Task<Never, Never>.isCancelled || Date() >= raw.assumingMemoryBound(to: Date.self).pointee ? 1 : 0
            }, UnsafeMutableRawPointer(mutating: pointer))
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            func scalar(_ sql: String) -> (Int32, String?) {
                var statement: OpaquePointer?
                let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
                guard status == SQLITE_OK, let statement else { if let statement { sqlite3_finalize(statement) }; return (status, nil) }
                defer { sqlite3_finalize(statement) }
                let step = sqlite3_step(statement)
                return (step, sqlite3_column_text(statement, 0).map { String(cString: $0) })
            }
            let (status, result) = scalar("PRAGMA quick_check(1)")
            if [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(status) || Task.isCancelled { return .unavailable }
            guard status == SQLITE_ROW, result == "ok" else { return .damaged }
            let (versionStatus, version) = scalar("PRAGMA user_version")
            if [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(versionStatus) { return .unavailable }
            guard versionStatus == SQLITE_ROW, version == expectedVersion else { return .damaged }
            let (schemaStatus, count) = scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (\(tables))")
            if [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(schemaStatus) { return .unavailable }
            return schemaStatus == SQLITE_ROW && count == "3" ? .healthy : .damaged
        }
        #else
        return .unavailable
        #endif
    }
}
