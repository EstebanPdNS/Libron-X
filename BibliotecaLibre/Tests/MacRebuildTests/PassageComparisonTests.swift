import Foundation
import Testing
import CSQLite
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct PassageComparisonTests {
    private func bible(_ root: URL, name: String, rows: String) throws -> LibraryResource {
        let url = root.appendingPathComponent(name + ".bbli")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('\(name)','\(name)','Authored test'); CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES " + rows + ";"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return try ESwordResource.inspect(url)
    }
    private func settle(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Passage comparison did not finish")
    }
    @Test func actualReadersCompareExportAndOpenExactVerseWithoutChangingBooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try bible(root, name: "Edition A", rows: "(1,1,1,'😀 In the beginning'),(1,1,2,'Light'),(1,1,3,'Third')")
        let b = try bible(root, name: "Edition B", rows: "(1,1,1,'😀 in beginning'),(1,1,3,'Third')")
        let before = try [a,b].map { try Data(contentsOf: $0.location) }
        let controller = PassageComparisonController()
        controller.selectedIDs = [a.id,b.id]; controller.baseID = a.id; controller.reference = "Ge1:1-3"
        controller.run(resources: [a,b]); try await settle { !controller.isLoading }
        #expect(controller.error == nil && controller.completed && controller.editions.allSatisfy(\.complete))
        #expect(controller.rows.count == 3 && controller.rows[1].cells[1].verse == nil)
        #expect(!controller.rows[0].cells[1].differences.isEmpty)
        #expect(try controller.exportCSV().contains("\"missing\""))
        controller.options.caseSensitive = false; controller.compareAgain(); try await settle { !controller.isLoading }
        #expect(controller.completed && controller.rows[0].cells[1].differences.count == 1)
        let workspace = StudyWorkspace(personal: .init(url: root.appendingPathComponent("personal.json")),
            resourceVisibility: .init(url: root.appendingPathComponent("visibility.json")),
            parallelBibleSets: .init(url: root.appendingPathComponent("parallel.json")),
            collections: .init(url: root.appendingPathComponent("collections.json")),
            resourcePriorities: .init(url: root.appendingPathComponent("priorities.json")))
        workspace.resources = [a,b]
        let edition = try #require(controller.editions.first), verse = try #require(edition.verses.last)
        let reader = try controller.open(verse, edition: edition, in: workspace)
        try await settle { !reader.isLoading }
        #expect(reader.error == nil && reader.selectedRange == verse.sourceRange.nsRange)
        #expect(reader.page.map { ($0.text as NSString).substring(with: reader.selectedRange).contains("Third") } == true)
        #expect(try [a,b].map { try Data(contentsOf: $0.location) } == before)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: a.location.path)
        #expect(throws: (any Error).self) { try controller.exportCSV() }
        #expect(throws: (any Error).self) { try controller.open(verse, edition: edition, in: workspace) }
        workspace.closeAll()
    }

    actor DelayedSource: LibrarySearchContentProvider {
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource { .init(articles: [.init(sectionOrdinal: 0, title: "Fixture")]) }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
            try? await Task.sleep(for: .milliseconds(120))
            return .init(text: "authored", bibleVerses: [.init(reference: "Ge1:1", normalizedReference: "ge 1:1", range: .init(location: 0, length: 8))])
        }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {}
    }
    @Test func cancelledOrSupersededReportCannotPublishStaleResults() async throws {
        var metadata = LibronMetadata(title: "Fixture", origin: "Test"); metadata.resourceType = "Biblia"
        let resource = LibraryResource(location: URL(fileURLWithPath: "/fixture.LSF"), title: "Fixture", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName, libron: metadata)
        let controller = PassageComparisonController(provider: DelayedSource())
        controller.selectedIDs = [resource.id]; controller.baseID = resource.id; controller.reference = "Ge1:1"
        controller.run(resources: [resource]); await Task.yield(); controller.cancel()
        try await Task.sleep(for: .milliseconds(180))
        #expect(!controller.isLoading && !controller.completed && controller.editions.isEmpty)
        controller.run(resources: [resource]); await Task.yield()
        controller.reference = "Ge1:2"; controller.run(resources: [resource]); try await settle { !controller.isLoading }
        #expect(controller.completed && controller.submittedReference == "Ge1:2")
        #expect(controller.rows.count == 1 && controller.rows[0].cells.allSatisfy { $0.verse == nil })
    }
}
