import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct VerseListTextControllerTests {
    actor DelayedSource: LibrarySearchContentProvider {
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            .init(articles: [.init(sectionOrdinal: 0, title: "Fixture")])
        }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor,
                  prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
            try? await Task.sleep(for: .milliseconds(100))
            return .init(text: "Own text", bibleVerses: [.init(reference: "Ge1:1", normalizedReference: "ge 1:1",
                range: .init(location: 0, length: 8))])
        }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws { }
    }
    @Test func invalidatedOrSupersededLoadsNeverPublishOldRows() async throws {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/fixture.LSF"), title: "Fixture", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        var document = StudyDocument(title: "List", kind: .verseList)
        document.verses = [StudyVerseEntry(reference: "Ge1:1")]
        let controller = VerseListTextController(provider: DelayedSource())
        controller.load(document: document, resource: resource)
        await Task.yield(); controller.invalidate()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!controller.isLoading && controller.report == nil && controller.rowsByID.isEmpty)
        controller.load(document: document, resource: resource)
        await Task.yield()
        document.verses = [StudyVerseEntry(reference: "Ge1:2")]
        controller.load(document: document, resource: resource)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!controller.isLoading && controller.report?.rows.map(\.entryID) == document.verses.map(\.id))
        #expect(controller.report?.rows.first?.state == .missing)
    }
}
