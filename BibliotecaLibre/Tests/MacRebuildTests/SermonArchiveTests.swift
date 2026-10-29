import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct SermonArchiveTests {
    @Test func saveEditSearchReportHistoryAndRecoveryKeepTheSameTypedContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        var metadata = SermonMetadata(); metadata.speaker = "Ana"; metadata.series = "Vida nueva"
        metadata.venue = "Comunidad"; metadata.tags = ["esperanza"]; metadata.passages = ["Jn 3:16"]
        metadata.preachedOn = try ReadingDay(year: 2026, month: 10, day: 29)
        let id = try state.saveSermonDetails(original: nil, title: "Fe", metadata: metadata)
        var note = StudyNote(title: "Inicio"); note.sourceBody = "<p>😀 Acción y oración</p>"
        state.documents[0].notes = [note]; try state.save()
        let original = state.documents[0]
        var changed = metadata; changed.speaker = "Eva"
        try state.saveSermonDetails(original: original, title: "Fe renovada", metadata: changed)
        #expect(state.documents[0].notes == [note] && state.documents[0].sermon == changed)
        let reloaded = WorkspacePersonalState(url: url)
        #expect(reloaded.documents == state.documents)
        for query in ["renovada", "Eva", "nueva", "Comunidad", "esperanza", "3:16", "2026-10-29", "accion"] {
            #expect(try SermonArchiveSearch.search(query, documents: reloaded.documents, order: .newest).documents.map(\.id) == [id])
        }
        let report = try NotebookReport.make(document: state.documents[0], selected: [note.id], includeBody: true, includeReferences: true).string
        #expect(report.contains("Eva") && report.contains("2026-10-29") && report.contains("Jn 3:16") && report.contains("Acción"))
        let history = try reloaded.documentHistory()
        let prior = try #require(history.versions.first { $0.document == original })
        try reloaded.recoverDocumentVersion(prior, title: "Recovered")
        let recovered = try #require(reloaded.documents.last)
        #expect(recovered.kind == .sermon && recovered.schemaVersion == 3 && recovered.sermon == metadata)
        #expect(recovered.id != id && recovered.notes[0].id != note.id && recovered.notes[0].sourceBody == note.sourceBody)
        try reloaded.deleteSermon(reloaded.documents[0])
        #expect(try reloaded.documentHistory().versions.contains { $0.document.title == "Fe renovada" })
    }
    @Test func invalidAndStaleDetailsNeverOverwriteCurrentContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        try state.saveSermonDetails(original: nil, title: "Initial", metadata: SermonMetadata())
        let original = state.documents[0]
        var invalid = SermonMetadata(); invalid.passages = ["unknown book"]
        let bytes = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try state.saveSermonDetails(original: original, title: "Invalid", metadata: invalid) }
        #expect(try Data(contentsOf: url) == bytes && state.documents[0] == original)
        state.documents[0].notes.append(StudyNote(title: "Concurrent note"))
        try state.saveSermonDetails(original: original, title: "Changed", metadata: SermonMetadata())
        #expect(state.documents[0].notes.count == 1)
        #expect(throws: PersonalStateError.self) { try state.saveSermonDetails(original: original, title: "Stale", metadata: SermonMetadata()) }
        #expect(throws: PersonalStateError.self) { try state.deleteSermon(original) }
    }
    @Test func searchHandlesVisibleRichTextAndPartialProjectionsWithoutInventingHits() throws {
        var sermon = StudyDocument(title: "Sermon", kind: .sermon)
        var note = StudyNote(title: "Owned")
        note.sourceBody = "<p>Fallback</p><img src='missing'>"; note.editedRTF = Data("invalid".utf8)
        sermon.notes = [note]
        let partial = try SermonArchiveSearch.search("Fallback", documents: [sermon], order: .title)
        #expect(partial.documents.count == 1 && partial.incompleteDocuments == 1)
        sermon.notes[0].editedRTF = try NoteRichTextCodec.encode(NSAttributedString(string: "Edited λόγος"))
        #expect(try SermonArchiveSearch.search("λόγος", documents: [sermon], order: .speaker).documents.count == 1)
        #expect(try SermonArchiveSearch.search("Fallback", documents: [sermon], order: .title).documents.isEmpty)
        #expect(throws: PersonalStateError.self) { try SermonArchiveSearch.search(String(repeating: "x", count: 513), documents: [sermon], order: .title) }
    }
    @Test func metadataPassagesParticipateInReferenceSearchAndQuitCanProtectDrafts() async throws {
        var document = StudyDocument(title: "Owned", kind: .sermon)
        document.sermon!.passages = ["Jn 3:16"]
        let source = try PersonalReferenceProjection.source(document)
        let report = try await BibleReferenceSearchService(provider: WorkspaceSearchReader()).search(resources: [],
            documents: [source], query: BibleReferenceQuery.parse("John 3:16"))
        let destination = try #require(report.results.first?.personalDestination)
        #expect(destination.field == .sermonPassages && destination.entryID == nil)
        _ = try PersonalReferenceProjection.validate(destination, documents: [document])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: root.appendingPathComponent("personal.json")))
        let lifecycle = RebuildLifecycle(); lifecycle.workspace = workspace
        workspace.sermonDraftCloseGuard = { false }
        #expect(lifecycle.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("personal.json").path))
        workspace.sermonDraftCloseGuard = nil
        workspace.shutdown()
    }
    @Test func datesSortWithUndatedEntriesLastAndDraftsKeepCivilDatesAndReferences() throws {
        var first = StudyDocument(title: "A", kind: .sermon), second = StudyDocument(title: "B", kind: .sermon)
        first.sermon!.preachedOn = try ReadingDay(year: 2026, month: 3, day: 8)
        second.sermon!.preachedOn = try ReadingDay(year: 2026, month: 10, day: 29)
        first.sermon!.passages = ["Jn 3:16", "Romanos 8:1"]
        let undated = StudyDocument(title: "C", kind: .sermon)
        let notebook = StudyDocument(title: "Not a sermon", kind: .notebook)
        let docs = [undated, first, notebook, second]
        #expect(try SermonArchiveSearch.search("", documents: docs, order: .newest).documents.map(\.id) == [second.id, first.id, undated.id])
        #expect(try SermonArchiveSearch.search("", documents: docs, order: .oldest).documents.map(\.id) == [first.id, second.id, undated.id])
        let draft = SermonDetailsDraft(document: first)
        #expect(try draft.metadata() == first.sermon)
        let source = try PersonalReferenceProjection.source(first)
        let field = try #require(source.fields.first { $0.kind == .sermonPassages })
        #expect(field.text == "Jn 3:16\nRomanos 8:1")
        let extraction = try StudyReferenceExtraction.document(first)
        #expect(extraction.items.map(\.reference) == first.sermon!.passages)
        try extraction.validate(against: [first])
        first.sermon!.passages = ["Jn 3:17"]
        #expect(throws: PersonalStateError.self) { try extraction.validate(against: [first]) }
    }
}
