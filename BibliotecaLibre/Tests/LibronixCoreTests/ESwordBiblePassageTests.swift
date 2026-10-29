import CSQLite
import Foundation
import Testing
@testable import LibronixCore

struct ESwordBiblePassageTests {
    private func fixture(_ rows: String, table: String = "CREATE TABLE Bible(Book,Chapter,Verse,Scripture);") throws -> LibraryResource {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copy-esword-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("owned.bbli")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information);INSERT INTO Details VALUES('Owned Bible','Own','Authored test');" + table + rows
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return .init(location: url, title: "Owned Bible", byteCount: 0, format: .eSwordSQLite, support: .metadataOnly, provenance: .fileName,
                     stableID: "owned-edition-" + UUID().uuidString)
    }
    private func remove(_ resource: LibraryResource) { try? FileManager.default.removeItem(at: resource.location.deletingLastPathComponent()) }

    @Test func exactSourceRangesRetainEncodedBodiesChapterOrdinalsAndEditionIdentity() throws {
        let resource = try fixture("INSERT INTO Bible VALUES(1,1,2,'<i>Second שָׁלוֹם</i>'),(1,1,1,'<b>First 😀</b>'),(1,2,1,'{\\rtf1 Next}'),(2,1,1,'Other book');")
        defer { remove(resource) }
        let original = try Data(contentsOf: resource.location)
        let chapter = try ESwordResource.biblePassage(resource, passage: .parse("Genesis 1"))
        #expect(chapter.resource == resource && chapter.verses.map(\.sectionOrdinal) == [0,0])
        #expect(chapter.verses.map(\.encodedBody) == ["<b>First 😀</b>", "<i>Second שָׁלוֹם</i>"])
        #expect(chapter.encodedCharacterCount == chapter.verses.reduce(0) { $0 + $1.encodedBody.utf16.count })
        let span = try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:2-2:1"))
        #expect(span.verses.map(\.sectionOrdinal) == [0,1] && span.verses.map(\.address.key) == ["ge 1:2","ge 2:1"])
        #expect(span.verses.last?.encodedBody == "{\\rtf1 Next}")
        let books = try ESwordResource.biblePassage(resource, passage: .parse("Ge 2:1-Ex 1:1"))
        #expect(books.verses.map(\.sectionOrdinal) == [1,2])
        try span.verifyUnchanged()
        #expect(try Data(contentsOf: resource.location) == original)
    }
    @Test(arguments: [
        "INSERT INTO Bible VALUES(1,1,1,'One'),(1,1,1,'Duplicate'),(1,1,2,'Two');",
        "INSERT INTO Bible VALUES(1,1,1,'One'),(1,1,3,'Three');",
        "INSERT INTO Bible VALUES(1,1,1,'One'),(1,1,2,'');",
        "INSERT INTO Bible VALUES(1,1,1,'One'),(1,1,2,NULL);",
        "INSERT INTO Bible VALUES(1,1,1,'One'),(1,1,2,'head'||char(0)||'tail');",
        "INSERT INTO Bible VALUES(1,1,1,'One'),(1,1,2,CAST(X'FF' AS TEXT));",
        "INSERT INTO Bible VALUES(1,1,1,'One'),(1,1,2,X'616263');"
    ])
    func malformedOrMissingTextCannotProduceACompletePassage(rows: String) throws {
        let resource = try fixture(rows); defer { remove(resource) }
        #expect(throws: (any Error).self) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1-3")) }
        #expect(throws: (any Error).self) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 1")) }
    }
    @Test func boundsMissingEndpointsAndSkippedChaptersOrBooksAreExplicit() throws {
        let resource = try fixture("INSERT INTO Bible VALUES(1,1,1,'😀'),(1,1,2,'Two'),(1,3,1,'Skipped chapter'),(3,1,1,'Skipped book');")
        defer { remove(resource) }
        #expect(try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1"), maximumCharacters: 2).encodedCharacterCount == 2)
        #expect(throws: BibleCopyError.limitExceeded) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1"), maximumCharacters: 1) }
        #expect(throws: BibleCopyError.limitExceeded) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1-3:1"), maximumArticles: 1) }
        #expect(throws: BibleCopyError.missingBoundary) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:3")) }
        #expect(throws: BibleCopyError.incompleteSource) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1-3:1")) }
        #expect(throws: BibleCopyError.incompleteSource) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 3:1-Le 1:1")) }
        #expect(throws: BibleCopyError.reversedPassage) { try ESwordResource.biblePassage(resource, passage: .parse("Le 1:1-Ge 1:1")) }
    }
    @Test func aSmallExactVerseDoesNotReadOrChargeLaterUnselectedBodies() throws {
        let resource = try fixture("INSERT INTO Bible VALUES(1,1,1,'One'),(1,1,2,'" + String(repeating: "x", count: 100_000) + "');")
        defer { remove(resource) }
        let passage = try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1"), maximumCharacters: 3)
        #expect(passage.verses.count == 1 && passage.verses[0].encodedBody == "One")
        #expect(throws: BibleCopyError.limitExceeded) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 1"), maximumCharacters: 3) }
    }
    @Test func changedWALAndNewJournalInvalidateTheSnapshotEvenWhenMainBytesStayUnchanged() throws {
        let resource = try fixture("INSERT INTO Bible VALUES(1,1,1,'Original');"); defer { remove(resource) }
        var writer: OpaquePointer?
        #expect(sqlite3_open(resource.location.path, &writer) == SQLITE_OK); defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "PRAGMA journal_mode=WAL;UPDATE Bible SET Scripture='Before';", nil, nil, nil) == SQLITE_OK)
        let selected = try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1"))
        let main = try Data(contentsOf: resource.location)
        #expect(sqlite3_exec(writer, "UPDATE Bible SET Scripture='After';", nil, nil, nil) == SQLITE_OK)
        #expect(try Data(contentsOf: resource.location) == main)
        #expect(throws: LegacyIndicesError.sourceChanged) { try selected.verifyUnchanged() }
        let current = try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1"))
        #expect(current.verses[0].encodedBody == "After")
        try Data().write(to: URL(fileURLWithPath: resource.location.path + "-journal"))
        #expect(throws: LegacyIndicesError.sourceChanged) { try current.verifyUnchanged() }
    }
    @Test func aReferenceOrProtectedDatabaseCannotBeTreatedAsABible() throws {
        let resource = try fixture("INSERT INTO Reference VALUES('Article','Body');", table: "CREATE TABLE Reference(Chapter,Content);")
        defer { remove(resource) }
        #expect(throws: ReaderOutputError.unsupportedFormat) { try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1")) }
    }
    @Test func cancellationIsHonoredBeforeTheFirstSourceRead() async throws {
        let resource = try fixture("INSERT INTO Bible VALUES(1,1,1,'One');"); defer { remove(resource) }
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1"))
        }
        await #expect(throws: CancellationError.self) { try await work.value }
    }
}
