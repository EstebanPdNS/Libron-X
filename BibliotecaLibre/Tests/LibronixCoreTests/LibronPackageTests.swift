import Foundation
import Testing
@testable import LibronixCore
#if canImport(CSQLite)
import CSQLite
#endif

struct LibronPackageTests {
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("libron-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    @Test func roundTripRetainsIdentityIndexAndExactBytesWithOptionalBackup() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.LSF"), index = root.appendingPathComponent("book.LIX")
        try Data("Original body 😀".utf8).write(to: source); try Data("Index".utf8).write(to: index)
        let resource = LibraryResource(location: source, indexLocation: index, title: "A / Book: title", author: "Author", languages: ["es"], byteCount: 18,
            format: .legacyLSF, support: .metadataOnly, provenance: .legacyPublicMetadata)
        let library = root.appendingPathComponent("Library")
        let package = try LibronPackage.create(resource, in: library, backup: true)
        let (manifest, imported) = try LibronPackage.read(package, verify: true)
        #expect(imported.id == resource.id && imported.title == resource.title)
        #expect(imported.fileName.hasSuffix(".libron"))
        #expect(imported.location.lastPathComponent == "book.LSF")
        #expect(try Data(contentsOf: imported.location) == Data(contentsOf: source))
        #expect(try Data(contentsOf: imported.indexLocation!) == Data(contentsOf: index))
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("backup/" + manifest.payload.sha256 + "/book.LSF").path))
        #expect(try LibronPackage.create(resource, in: library, backup: true) == package)
        let snapshot = try await LibraryImporter().importDirectory(at: library)
        #expect(snapshot.resources.count == 1)
        #expect(snapshot.resources[0].id == resource.id)
        let noBackup = root.appendingPathComponent("NoBackup")
        _ = try LibronPackage.create(resource, in: noBackup, backup: false)
        #expect(!FileManager.default.fileExists(atPath: noBackup.appendingPathComponent("backup").path))
        #expect(try Data(contentsOf: source) == Data("Original body 😀".utf8))
    }
    @Test func tamperedPayloadUnsupportedVersionsAndTraversalAreRejected() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.bbli"); try Data("AAAA".utf8).write(to: source)
        let resource = LibraryResource(location: source, title: "Sample", byteCount: 4, format: .eSwordSQLite, support: .metadataOnly, provenance: .fileName)
        let package = try LibronPackage.create(resource, in: root.appendingPathComponent("Library"), backup: false)
        let (manifest, imported) = try LibronPackage.read(package)
        try Data("BBBB".utf8).write(to: imported.location)
        #expect(throws: LibronError.self) { try LibronPackage.read(package, verify: true) }
        try Data("AAAA".utf8).write(to: imported.location)
        var invalid = manifest; invalid.schemaVersion = 99
        try JSONEncoder().encode(invalid).write(to: package.appendingPathComponent("manifest.json"))
        #expect(throws: LibronError.self) { try LibronPackage.read(package) }
        invalid = manifest; invalid.payload.path = "../sample.bbli"
        try JSONEncoder().encode(invalid).write(to: package.appendingPathComponent("manifest.json"))
        #expect(throws: LibronError.self) { try LibronPackage.read(package) }
    }
    #if canImport(CSQLite)
    func database(_ root: URL, name: String, sql: String) throws -> URL {
        let url = root.appendingPathComponent(name); var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK); defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LibronError.invalid("Fixture SQL failed") }
        return url
    }
    @Test func eswordSchemasKeepVerseOrderUnicodeAndCommentaryIntroductions() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let details = "CREATE TABLE Details(Title, Abbreviation, Information); INSERT INTO Details VALUES('Test','T','Authored fixture');"
        let bible = try database(root, name: "test.bblx", sql: details + "CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,2,'Second'),(1,1,1,'First 😀'),(1,2,1,'Next'),(67,1,1,'Tobit'),(73,1,1,'Second Maccabees');")
        #expect(try ESwordResource.inspect(bible).libron?.resourceType == "Biblia")
        let page = try ESwordResource.page(bible, ordinal: 0)
        #expect(page.entries.map(\.body) == ["First 😀","Second"])
        #expect(page.entries.map(\.reference) == ["Ge 1:1","Ge 1:2"])
        #expect(try ESwordResource.page(bible, ordinal: 0, reference: "Ge 2:1").ordinal == 1)
        #expect(try ESwordResource.page(bible, ordinal: 2).entries.first?.reference == "Tob 1:1")
        #expect(try ESwordResource.page(bible, ordinal: 3).entries.first?.reference == "2Ma 1:1")
        let comment = try database(root, name: "test.cmti", sql: details + "CREATE TABLE BookCommentary(Book,Comments); CREATE TABLE ChapterCommentary(Book,Chapter,Comments); CREATE TABLE VerseCommentary(Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd,Comments); INSERT INTO BookCommentary VALUES(1,'Introduction'); INSERT INTO ChapterCommentary VALUES(1,1,'Chapter'); INSERT INTO VerseCommentary VALUES(1,1,1,1,2,'Verses');")
        #expect(try ESwordResource.page(comment, ordinal: 0).contents.count == 3)
        #expect(try ESwordResource.page(comment, ordinal: 0).entries[0].body == "Introduction")
        #expect(try ESwordResource.page(comment, ordinal: 2).entries[0].body == "Verses")
    }
    #endif
    @Test func namesRemainBoundedAndDistinctWithoutLosingUnicode() {
        var m = LibronMetadata(title: String(repeating: "א😀/", count: 150), origin: "e-Sword")
        m.authors = ["Name: author"]
        let one = LibronPackage.filename(m, hash: String(repeating: "a", count: 64)), two = LibronPackage.filename(m, hash: String(repeating: "b", count: 64))
        #expect(one.utf8.count < 255 && !one.contains("/") && one != two)
    }
}
