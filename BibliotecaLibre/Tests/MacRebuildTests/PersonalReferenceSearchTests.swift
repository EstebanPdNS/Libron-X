import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct PersonalReferenceSearchTests {
    private func notebook() -> StudyDocument {
        var doc = StudyDocument(title: "Study John3:16", kind: .notebook)
        var note = StudyNote(title: "Title John3:17", anchor: .init(kind: .legacyReference,
            legacyAttributes: ["reference": "bible+rvr60.64.3.19"]))
        note.sourceBody = #"<p>😀 <span lbxrt:xref="bible+esv.64.3.18"><b>18</b><i>–20</i></span></p><script>John3:99</script><p>John3:21</p>"#
        doc.notes = [note]; return doc
    }
    private func search(_ documents: [StudyDocument], _ query: String = "John3") async throws -> BibleReferenceSearchReport {
        try await BibleReferenceSearchService(provider: WorkspaceSearchReader()).search(resources: [],
            documents: documents.map(PersonalReferenceProjection.source), query: BibleReferenceQuery.parse(query))
    }
    private func settle(_ controller: WorkspaceReferenceSearchController) async throws {
        for _ in 0..<2000 {
            if !controller.isSearching { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Reference search did not settle")
    }
    @Test func actualEditorProjectionPreservesMarkupSourceAndSeparateFields() async throws {
        let doc = notebook()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(doc)
        let source = try PersonalReferenceProjection.source(doc)
        let note = try #require(doc.notes.first)
        let body = try #require(source.fields.first { $0.kind == .noteBody })
        #expect(body.text == NoteHTMLProjection.spans(note.sourceBody).map(\.text).joined())
        #expect(body.links.count == 1 && body.links[0].range == .init(location: 3, length: 5))
        let report = try await search([doc])
        #expect(report.coverageComplete && report.results.count == 5)
        #expect(report.results.map { $0.mention.citation.spans[0].lower.verse } == [16,17,18,21,19])
        #expect(report.results.filter { $0.mention.origin == .explicitLink }.map(\.mention.label) == ["18–20"])
        #expect(report.results.allSatisfy { $0.personalDestination != nil && $0.resourceDestination == nil })
        #expect(try await search([doc], "John3:99").results.isEmpty)
        #expect(try encoder.encode(doc) == before)
        var split = StudyDocument(title: "John", kind: .notebook)
        var plain = StudyNote(title: "3:16"); plain.sourceContentType = "text/plain"; plain.sourceBody = "3:16"
        split.notes = [plain]
        #expect(try await search([split]).results.isEmpty)
    }
    @Test func invisibleLinkEditsDeletedEntriesAndChangedFieldsRejectStaleDestinations() async throws {
        let original = notebook()
        let result = try #require(try await search([original], "John3:18(ESV)").results.first?.personalDestination)
        let verified = try PersonalReferenceProjection.validate(result, documents: [original])
        #expect(verified.kind == .noteBody)
        for mode in 0..<4 {
            var changed = original
            switch mode {
            case 0: changed.notes[0].sourceBody = changed.notes[0].sourceBody.replacingOccurrences(of: "bible+esv.64.3.18", with: "bible+esv.64.3.19")
            case 1: changed.notes[0].sourceBody += "changed"
            case 2: changed.notes.removeAll()
            default: changed.id = UUID()
            }
            #expect(throws: PersonalStateError.self) { try PersonalReferenceProjection.validate(result, documents: [changed]) }
        }
        var unrelated = original; unrelated.title = "Renamed document"; unrelated.notes[0].title = "Renamed note"
        #expect(try PersonalReferenceProjection.validate(result, documents: [unrelated]).text == verified.text)
    }
    @Test func verseListsPlainEditorsAndUnsupportedRichEditsHaveHonestCoverage() async throws {
        var list = StudyDocument(title: "Passages", kind: .verseList)
        list.verses = [.init(reference: "John3:16(RVR60)"), .init(reference: "Jude11")]
        let listReport = try await search([list])
        #expect(listReport.coverageComplete && listReport.results.count == 1)
        #expect(listReport.results.first?.personalDestination?.entryID == list.verses[0].id)
        #expect(listReport.results.first?.personalDestination?.field == .verseEntry)
        var doc = notebook(); doc.notes[0].sourceContentType = "text/plain"
        doc.notes[0].sourceBody = "Literal <b>John3:22</b> 😀"
        doc.notes[0].editedRTF = Data("John3:99".utf8)
        let source = try PersonalReferenceProjection.source(doc)
        #expect(source.fields.first { $0.kind == .noteBody }?.text == doc.notes[0].sourceBody)
        #expect(!source.projectionComplete && source.warnings.count == 1)
        let report = try await search([doc], "John3:99")
        #expect(!report.coverageComplete && report.results.isEmpty && report.documents[0].warnings.count == 1)
    }
    @Test func controllerClearsInvalidScopesCancelsAndKeepsNewestQuery() async throws {
        let doc = notebook(), controller = WorkspaceReferenceSearchController()
        controller.includeLibrary = false; controller.query = "John3:18(ESV)"
        controller.run(resources: [], documents: [doc]); try await settle(controller)
        #expect(controller.error == nil && controller.report?.results.count == 1)
        controller.query = "not a citation"; controller.run(resources: [], documents: [doc])
        #expect(controller.error != nil && controller.report == nil && !controller.isSearching)
        controller.query = "John3:16"; controller.run(resources: [], documents: [doc]); controller.cancel()
        controller.query = "John3:17"; controller.run(resources: [], documents: [doc]); try await settle(controller)
        #expect(controller.report?.query == "John3:17" && controller.report?.results.count == 1)
        controller.includeDocuments = false; controller.run(resources: [], documents: [doc])
        #expect(controller.error != nil && controller.report == nil && !controller.isSearching)
    }
    @Test func openingPersonalResultsSelectsExactDocumentEntryAndRejectsEditedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal,
            resourceVisibility: .init(url: root.appendingPathComponent("visibility.json")),
            parallelBibleSets: .init(url: root.appendingPathComponent("parallel.json")),
            collections: .init(url: root.appendingPathComponent("collections.json")),
            resourcePriorities: .init(url: root.appendingPathComponent("priorities.json")))
        let doc = notebook(); personal.documents = [doc]
        let result = try #require(try await search([doc], "John3:18(ESV)").results.first)
        workspace.openReferenceSearchResult(result)
        #expect(workspace.activeTool == .documents && workspace.personal.selectedDocumentID == doc.id)
        #expect(workspace.personalSearchDestination?.entryID == doc.notes[0].id && workspace.readers.isEmpty)
        let navigation = workspace.personalNavigationID
        personal.documents[0].notes[0].sourceBody += " changed"
        workspace.activeTool = .referenceSearch; workspace.openReferenceSearchResult(result)
        #expect(workspace.referenceSearch.error != nil && workspace.error == nil && workspace.activeTool == .referenceSearch && workspace.personalNavigationID == navigation)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("personal.json").path))
    }
}
