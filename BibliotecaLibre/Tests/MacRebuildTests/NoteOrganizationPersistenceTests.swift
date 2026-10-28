import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct NoteOrganizationPersistenceTests {
    @Test func hierarchyMovesCopiesPropertiesAndOrderSurviveReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        var first = StudyDocument(title: "First", kind: .notebook)
        var note = StudyNote(title: "Original"); note.sourceAttributes = ["author":"Original author"]
        first.notes = [note, StudyNote(title: "Sibling")]
        var second = StudyDocument(title: "Second", kind: .notebook); second.notes = [StudyNote(title: "Parent")]
        state.documents = [first, second]; try state.save()
        try state.moveNotes([note.id], from: first.id, to: second.id, parentID: second.notes[0].id)
        try state.setNoteProperties(note.id, in: second.id, values: ["author":"Owned author", "tags":"Owned"])
        let copies = try state.duplicateNotes([note.id], in: second.id)
        #expect(copies.count == 1)
        let copiedID = try #require(copies.first)
        try state.moveNote(copiedID, in: second.id, by: -1)
        let restored = WorkspacePersonalState(url: url)
        #expect(restored.loadError == nil && restored.documents == state.documents)
        let moved = try #require(restored.documents[1].notes.first { $0.id == note.id })
        #expect(moved.parentID == second.notes[0].id && moved.sourceAttributes == note.sourceAttributes && moved.properties?["author"] == "Owned author")
        #expect(restored.documents[1].notes.filter { $0.parentID == second.notes[0].id }.map(\.id) == [copiedID,note.id])
    }

    @Test func failedPropertyValidationRollsBackTheWholeDocumentAndSavedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), state = WorkspacePersonalState(url: url)
        var doc = StudyDocument(title: "Owned", kind: .notebook); doc.notes = [StudyNote(title: "Unchanged")]
        state.documents = [doc]; try state.save()
        let before = try Data(contentsOf: url)
        #expect(throws: PersonalStateError.self) { try state.setNoteProperties(doc.notes[0].id, in: doc.id, values: ["author":String(repeating: "x", count: 4_097)]) }
        let after = try Data(contentsOf: url)
        #expect(state.documents == [doc] && after == before)
    }
}
