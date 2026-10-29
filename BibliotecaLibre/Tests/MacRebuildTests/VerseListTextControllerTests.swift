import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct VerseListTextControllerTests {
    actor DelayedSource: LibrarySearchContentProvider {
        private(set) var preparations = 0
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            preparations += 1
            return .init(articles: [.init(sectionOrdinal: 0, title: "Fixture")])
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
    @Test func savedEditionsReloadAutomaticallyAndUnrelatedPresentationChangesDoNotRescan() async throws {
        let a = LibraryResource(location: URL(fileURLWithPath: "/owned-a.LSF"), title: "A", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: "A")
        let b = LibraryResource(location: URL(fileURLWithPath: "/owned-b.LSF"), title: "B", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: "B")
        var document = StudyDocument(title: "List", kind: .verseList)
        document.schemaVersion = 4; document.verseListEdition = .init(a)
        document.verses = [.init(reference: "Ge1:1")]
        let source = DelayedSource(), controller = VerseListTextController(provider: source)
        controller.synchronize(document: document, resources: [a,b]); try await settle(controller)
        #expect(controller.report?.edition?.resource == a && controller.rowsByID.count == 1)
        document.title = "Renamed"; document.presentation = "TextOnly"
        controller.synchronize(document: document, resources: [a,b])
        let firstCount = await source.preparations
        #expect(!controller.isLoading && firstCount == 1)
        document.verseListEdition = .init(b)
        controller.synchronize(document: document, resources: [a,b]); try await settle(controller)
        let secondCount = await source.preparations
        #expect(controller.report?.edition?.resource == b && secondCount == 2)
        controller.synchronize(document: document, resources: [a])
        #expect(controller.report == nil && controller.rowsByID.isEmpty && !controller.isLoading)
        #expect(document.verseListEdition?.resourceID == b.id)
        controller.synchronize(document: document, resources: [a,b]); controller.cancel()
        controller.synchronize(document: document, resources: [a,b])
        try await Task.sleep(for: .milliseconds(150))
        #expect(!controller.isLoading && controller.report == nil)
        controller.invalidate(); controller.synchronize(document: document, resources: [a,b]); try await settle(controller)
        #expect(controller.report?.edition?.resource == b)
    }
    @Test func twoListsRetainIndependentEditionsAcrossPersonalStateRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = LibraryResource(location: directory.appendingPathComponent("owned.LSF"), title: "Edition", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: "owned")
        var first = StudyDocument(title: "First", kind: .verseList)
        first.schemaVersion = 4; first.verseListEdition = .init(resource); first.presentation = "BothTwoColumns"
        first.verses = [.init(reference: "Ge1:1"), .init(reference: "John3:16")]
        var second = StudyDocument(title: "Second", kind: .verseList)
        second.verses = [.init(reference: "Ge1:2")]; second.presentation = "TextOnly"
        let path = directory.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: path)
        state.documents = [first,second]; try state.save()
        let reopened = WorkspacePersonalState(url: path)
        #expect(reopened.loadError == nil && reopened.documents == [first,second])
        #expect(reopened.documents[0].verseListEdition?.resolve(in: [resource]) == resource && reopened.documents[1].verseListEdition == nil)
    }
    private func settle(_ controller: VerseListTextController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!controller.isLoading && controller.error == nil)
    }

}
