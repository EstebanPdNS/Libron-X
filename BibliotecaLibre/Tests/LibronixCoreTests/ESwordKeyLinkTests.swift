import Foundation
import Testing
import CSQLite
@testable import LibronixCore

struct ESwordKeyLinkTests {
    private func database(_ sql: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keylink-"+UUID().uuidString+".cmti")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path,&db) == SQLITE_OK);defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,"CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Fixture','F','Authored');"+sql,nil,nil,nil) == SQLITE_OK)
        return url
    }
    @Test func commentaryResolutionUsesNarrowestContainingSourceRangeThenChapterThenBook() throws {
        let url = try database("CREATE TABLE BookCommentary(Book,Comments); CREATE TABLE ChapterCommentary(Book,Chapter,Comments); CREATE TABLE VerseCommentary(Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd,Comments); INSERT INTO BookCommentary VALUES(1,'Book intro'); INSERT INTO ChapterCommentary VALUES(1,2,'Chapter intro'); INSERT INTO VerseCommentary VALUES(1,1,1,2,10,'Broad'),(1,1,2,1,4,'Narrow'),(1,1,2,1,4,'Equal duplicate'),(1,1,3,1,3,'Exact');")
        defer { try? FileManager.default.removeItem(at:url) }
        let before = try Data(contentsOf:url)
        for (query,end,body) in [("Ge 1:3",nil,"Exact"),("Ge 1:2",nil,"Narrow"),("Ge 1:2","Ge 1:4","Narrow"),("Ge 1:2","Ge 2:2","Broad"),("Ge 2:11",nil,"Chapter intro"),("Ge 9:1",nil,"Book intro")] {
            let ordinal = try #require(try ESwordResource.referenceOrdinal(url,reference:query,endReference:end))
            #expect(try ESwordResource.page(url,ordinal:ordinal).entries.first?.body == body)
        }
        #expect(try ESwordResource.referenceOrdinal(url,reference:"Ex 1:1") == nil)
        #expect(try ESwordResource.referenceOrdinal(url,reference:"Ge 1:2",endReference:"not a reference") == nil)
        #expect(try ESwordResource.referenceOrdinal(url,reference:"Ge 1:3",endReference:"Ge 1:2") == nil)
        #expect(try ESwordResource.referenceOrdinal(url,reference:"Ge 1:3",endReference:"Ex 1:2") == nil)
        #expect(try ESwordResource.referenceOrdinal(url,reference:"'; DROP TABLE VerseCommentary; --") == nil)
        #expect(try Data(contentsOf:url) == before)
    }
    @Test func bibleResolutionRequiresAnActualVerseAndMalformedCommentaryFailsExplicitly() throws {
        let bible = try database("CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'One'),(1,2,3,'Sparse three');")
        defer { try? FileManager.default.removeItem(at:bible) }
        #expect(try ESwordResource.referenceOrdinal(bible,reference:"Ge 2:3") == 1)
        #expect(try ESwordResource.referenceOrdinal(bible,reference:"Ge 2:1") == nil)
        #expect(try ESwordResource.referenceOrdinal(bible,reference:"Ge 9:1") == nil)
        let malformed = try database("CREATE TABLE BookCommentary(Book,Comments); CREATE TABLE ChapterCommentary(Book,Chapter,Comments); CREATE TABLE VerseCommentary(Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd,Comments); INSERT INTO VerseCommentary VALUES(1,2,1,1,1,'Reversed');")
        defer { try? FileManager.default.removeItem(at:malformed) }
        #expect(throws:(any Error).self) { try ESwordResource.referenceOrdinal(malformed,reference:"Ge 1:1") }
    }
}
