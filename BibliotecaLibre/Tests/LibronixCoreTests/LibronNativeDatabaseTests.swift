import Foundation
import Testing
@testable import LibronixCore
#if canImport(CSQLite)
import CSQLite

struct LibronNativeDatabaseTests {
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
