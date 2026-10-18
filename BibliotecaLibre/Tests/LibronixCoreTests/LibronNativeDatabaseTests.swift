import Foundation
import Testing
@testable import LibronixCore
#if canImport(CSQLite)
import CSQLite

struct LibronNativeDatabaseTests {
    @Test func previouslyStoredJoKeysRemainReadableWithoutMutatingNormalizedBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let db = try LibronNativeDatabase(url, create: true)
            try db.add(reference: "2Jo1:1", ordinal: 17, offset: 3)
            try db.add(reference: "3Jo1:2", ordinal: 18, offset: 7)
            try db.add(reference: "Ge1:1", ordinal: 0, offset: 0)
            try db.finish()
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE bible_v1 SET book='2jo' WHERE book='2jn'; UPDATE bible_v1 SET book='3jo' WHERE book='3jn'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url), reader = try LibronNativeDatabase(url)
        #expect(try reader.resolve("2 John1:1")?.ordinal == 17)
        #expect(try reader.resolve("2Jo1:1")?.offset == 3)
        #expect(try reader.resolve("3 Juan1:2")?.ordinal == 18)
        #expect(try reader.resolve("Ge1:1")?.ordinal == 0)
        #expect(try reader.resolve("2 John1:2") == nil)
        #expect(try Data(contentsOf: url) == before)
    }
    @Test func sharedArticlesKeepNumericChapterOrderAndExposeEveryPhysicalFragmentReadOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let db = try LibronNativeDatabase(url, create: true)
            try db.add(reference: "Ge 2:1", ordinal: 10, offset: 11)
            try db.add(reference: "Ge 1:1", ordinal: 10, offset: 12)
            try db.add(reference: "Ge 1:15", ordinal: 11, offset: 0)
            try db.add(reference: "Ge 3:1", ordinal: 12, offset: 0)
            try db.add(reference: "Ex 1:1", ordinal: 10, offset: 5000)
            try db.finish()
        }
        let before = try Data(contentsOf: url), db = try LibronNativeDatabase(url)
        #expect(try db.chapterReferences() == ["ge 1:1", "ge 2:1", "ge 3:1", "ex 1:1"])
        #expect(try db.chapterSectionOrdinals("Ge 1:1") == [10, 11])
        #expect(try db.chapterSectionOrdinals("Ge 2:7") == [10])
        #expect(try Data(contentsOf: url) == before)
    }
    @Test func compressedRecordsCanonicalReferencesAndWordsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sqlite")
        defer { try? FileManager.default.removeItem(at:url) }
        let original = Data(String(repeating:"Definición 😀 א 字\n",count:4000).utf8)
        do {
            let db = try LibronNativeDatabase(url,create:true)
            try db.put("section/0",data:original)
            try db.add(reference:"Gen 1:1",ordinal:3,offset:17)
            try db.add(word:.init(headword:"Creación",ordinal:7))
            try db.finish()
        }
        let reader = try LibronNativeDatabase(url)
        #expect(try reader.get("section/0") == original)
        #expect(try reader.get("missing") == nil)
        #expect(try reader.resolve("Génesis 1:1")?.ordinal == 3)
        #expect(try reader.resolve("Ge 999:1") == nil)
        #expect(try reader.match("CREACIÓN")?.ordinal == 7)
        #expect(try reader.match("' OR 1=1 --") == nil)
        #expect(throws:LibronError.self) { try reader.put("x",data:Data()) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path,&db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,"UPDATE values_v1 SET sha256='invalid' WHERE key='section/0'",nil,nil,nil) == SQLITE_OK)
        #expect(throws:LibronError.self) { try reader.get("section/0") }
    }
}
#endif
