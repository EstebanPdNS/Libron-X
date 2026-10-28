import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

struct PersonalAnnotationSearchTests {
    actor Source: LibrarySearchContentProvider {
        let text: String
        var changed = false
        init(_ text: String) { self.text = text }
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            .init(articles: [.init(sectionOrdinal: 0, title: "Own article")])
        }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor,
                  prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle { .init(text: text) }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
            if changed { throw LegacyIndicesError.sourceChanged }
        }
        func change() { changed = true }
    }
    private func resource() -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/fixture.LSF"), title: "Own resource", byteCount: 0,
              format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
    }
    @Test func searchesNoteAndVerifiedHighlightWithFiltersAndExactCoordinates() async throws {
        let resource = resource(), text = "😀 Paz y esperanza en el mundo."
        let range = (text as NSString).range(of: "Paz y esperanza")
        let mark = ReaderHighlight(resourceID: resource.id, ordinal: 0,
            fingerprint: LibrarySearchService.textFingerprint(text), range: range, color: "yellow")
        var note = StudyNote(title: "Own note")
        note.sourceContentType = "text/plain"; note.sourceBody = "😀 La esperanza permanece."
        note.anchor = .init(kind: .nativeReference, location: .init(resourceID: resource.id, format: resource.format,
            sectionOrdinal: 0, textFingerprint: LibrarySearchService.textFingerprint(text)))
        var doc = StudyDocument(title: "Own notebook", kind: .notebook); doc.notes = [note]
        let search = PersonalAnnotationSearch(provider: Source(text))
        let report = try await search.search(query: "ESPERANZA", documents: [doc], highlights: [mark], resources: [resource], filter: .init())
        #expect(report.complete && report.results.count == 2)
        for result in report.results {
            #expect((result.snippet as NSString).substring(with: result.snippetMatch.nsRange).lowercased() == "esperanza")
            switch result.destination {
            case .note(let destination):
                let field = try PersonalReferenceProjection.validate(destination, documents: [doc])
                #expect((field.text as NSString).substring(with: destination.range.nsRange) == "esperanza")
            case .highlight(let original, _, _, let hit):
                #expect(original == mark && (text as NSString).substring(with: hit.nsRange) == "esperanza")
            }
        }
        var filter = PersonalAnnotationSearchFilter(); filter.color = "yellow"
        let highlighted = try await search.search(query: "esperanza", documents: [doc], highlights: [mark], resources: [resource], filter: filter)
        #expect(highlighted.results.count == 1)
        filter.color = nil; filter.documentID = doc.id
        let notebook = try await search.search(query: "esperanza", documents: [doc], highlights: [mark], resources: [resource], filter: filter)
        #expect(notebook.results.count == 1)
        filter.documentID = nil; filter.resourceID = "unrelated"
        let excluded = try await search.search(query: "esperanza", documents: [doc], highlights: [mark], resources: [resource], filter: filter)
        #expect(excluded.results.isEmpty)
    }
    @Test func accentInsensitiveMatchesKeepOriginalUnicodeOffsets() async throws {
        var note = StudyNote(title: "Own"); note.sourceContentType = "text/plain"; note.sourceBody = "😀 café y cafe\u{301}"
        var document = StudyDocument(title: "Own", kind: .notebook); document.notes = [note]
        let report = try await PersonalAnnotationSearch(provider: Source("")).search(query: "CAFE", documents: [document], highlights: [], resources: [], filter: .init())
        #expect(report.results.count == 2)
        for result in report.results {
            guard case .note(let destination) = result.destination else { Issue.record("Expected note"); continue }
            let original = (note.sourceBody as NSString).substring(with: destination.range.nsRange)
            #expect(original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == "cafe")
            #expect((result.snippet as NSString).substring(with: result.snippetMatch.nsRange) == original)
        }
    }
    @Test func unresolvedLegacyAnchorMakesResourceFilterExplicitlyPartial() async throws {
        let resource = resource()
        var note = StudyNote(title: "Legacy"); note.sourceContentType = "text/plain"; note.sourceBody = "found"
        note.anchor = .init(kind: .legacySelection, legacyAttributes: ["resource-id": "ambiguous"])
        var document = StudyDocument(title: "Notebook", kind: .notebook); document.notes = [note]
        var filter = PersonalAnnotationSearchFilter(); filter.resourceID = resource.id
        let result = try await PersonalAnnotationSearch(provider: Source("")).search(query: "found", documents: [document], highlights: [], resources: [resource], filter: filter)
        #expect(result.results.isEmpty && !result.complete && !result.warnings.isEmpty)
    }
    @Test func resultLimitIsExplicitAndKeepsUnchangedDocuments() async throws {
        var note = StudyNote(title: "Own"); note.sourceContentType = "text/plain"; note.sourceBody = "word word word"
        var document = StudyDocument(title: "Own", kind: .notebook); document.notes = [note]
        let original = document
        let search = PersonalAnnotationSearch(provider: Source(""))
        let report = try await search.search(query: "word", documents: [document], highlights: [], resources: [], filter: .init(), maximumResults: 2)
        #expect(report.results.count == 2 && !report.complete && !report.warnings.isEmpty)
        #expect(document == original)
    }
    @Test func staleMarksAndChangedFilesNeverProduceFalseResults() async throws {
        let resource = resource(), text = "A real verse", source = Source(text)
        let stale = ReaderHighlight(resourceID: resource.id, ordinal: 0, fingerprint: "old", range: NSRange(location: 0, length: 6), color: "blue")
        let valid = ReaderHighlight(resourceID: resource.id, ordinal: 0, fingerprint: LibrarySearchService.textFingerprint(text), range: NSRange(location: 0, length: 6), color: "blue")
        let search = PersonalAnnotationSearch(provider: source)
        let first = try await search.search(query: "real", documents: [], highlights: [stale,valid], resources: [resource], filter: .init())
        #expect(first.results.count == 1 && !first.complete && !first.warnings.isEmpty)
        await source.change()
        let changed = try await search.search(query: "real", documents: [], highlights: [valid], resources: [resource], filter: .init())
        #expect(changed.results.isEmpty && !changed.complete && !changed.warnings.isEmpty)
    }
}

@MainActor struct PersonalAnnotationControllerTests {
    actor DelayedSource: LibrarySearchContentProvider {
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource { .init(articles: [.init(sectionOrdinal: 0, title: "Own")]) }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
            try? await Task.sleep(for: .milliseconds(100)); return .init(text: "Own marked text")
        }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws { }
    }
    @Test func cancelPreventsStaleResults() async throws {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/fixture.LSF"), title: "Own", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let mark = ReaderHighlight(resourceID: resource.id, ordinal: 0, fingerprint: LibrarySearchService.textFingerprint("Own marked text"), range: NSRange(location: 0, length: 15), color: "blue")
        let controller = PersonalAnnotationSearchController(provider: DelayedSource()); controller.query = "marked"
        controller.run(documents: [], highlights: [mark], resources: [resource]); await Task.yield(); controller.clear()
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.report == nil && !controller.isSearching)
    }
}
