import AppKit
import CSQLite
import LibronixCore
import LibronixOutputMac
import Testing
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ESwordBibleCopyTests {
    @Test func projectsFormattedVerseRowsWithoutChangingTheSource() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("owned.bbli")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned Bible','OB','Fixture'); CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'<b>First 😀</b>'),(1,1,2,'<i><s>Second</s></i>'),(1,2,1,'Next');"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let resource = LibraryResource(location: url, title: "Owned Bible", byteCount: 0, format: .eSwordSQLite, support: .metadataOnly, provenance: .fileName)
        let before = try Data(contentsOf: url)
        let selection = try ESwordResource.biblePassage(resource, passage: .parse("Ge 1:1-2:1"))
        let document = try await ESwordBibleCopy.prepare(selection, abbreviation: "OB")
        #expect(document.resourceID == resource.id)
        #expect(document.verses.map(\.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } == ["First 😀", "Second", "Next"])
        #expect(document.verses[0].fragments.contains { $0.style?.font.weight == 700 })
        let formatted = try BibleCopyFormatter.format(document, style: BibleCopyOutputStyle())
        let output = try NativeBibleCopyOutput.prepare(formatted)
        #expect(output.text.contains("First 😀") && output.text.contains("Second"))
        #expect(String(decoding: output.html, as: UTF8.self).contains("<s>"))
        #expect(document.sources.map(\.verseReference) == selection.verses.map(\.reference))
        #expect(document.sourceParagraphs.count >= 3)
        #expect(try Data(contentsOf: url) == before)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_COPY_LLS"] != nil))
    func originalLLSBibleRetainsItsOuterIdentity() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_COPY_LLS"]))
        let resource = LibraryResource(location: url, title: "Bible", byteCount: 0, format: .libronixLLS, support: .metadataOnly, provenance: .fileName)
        let before = try LibrarySearchFileStamp.capture(url)
        let document = try await WorkspaceBibleCopy.prepare(resource, passage: .parse("Ge 1:1"), includeFootnotes: false)
        #expect(document.resourceID == resource.id && document.verses.first?.text.localizedCaseInsensitiveContains("principio") == true)
        try LibrarySearchFileStamp.verify([before])
    }

}
