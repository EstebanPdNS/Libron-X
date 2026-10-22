import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct NoteManagementTests {
    @Test func renamingAndBatchDeletionPersistWithoutChangingOtherNotesOrDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json")
        let state = WorkspacePersonalState(url: url)
        var notebook = StudyDocument(title: "Notebook", kind: .notebook)
        var first = StudyNote(title: "First")
        first.sourceBody = "Keep this body"; first.sourceAttributes = ["original": "retained"]
        notebook.notes = [first, StudyNote(title: "Second"), StudyNote(title: "Third")]
        var other = StudyDocument(title: "Other notebook", kind: .notebook)
        other.notes = [StudyNote(title: "Untouched")]
        state.documents = [notebook, other]; try state.save()
        try state.renameNote(first.id, in: notebook.id, title: "  Renamed  ")
        let renamed = state.documents[0].notes[0]
        #expect(renamed.title == "Renamed" && renamed.id == first.id)
        #expect(renamed.sourceBody == first.sourceBody && renamed.sourceAttributes == first.sourceAttributes && renamed.anchor == first.anchor)
        let ids = Set([first.id, notebook.notes[2].id, other.notes[0].id])
        try state.deleteNotes(ids, in: notebook.id)
        #expect(state.documents[0].notes == [notebook.notes[1]])
        #expect(state.documents[1] == other)
        let restored = WorkspacePersonalState(url: url)
        #expect(restored.loadError == nil && restored.documents == state.documents)
        try state.deleteNotes([notebook.notes[1].id], in: notebook.id)
        #expect(state.documents[0].notes.isEmpty && state.documents[1] == other)
        try state.renameNote(UUID(), in: notebook.id, title: "Missing")
        #expect(state.documents[0].notes.isEmpty)
    }
    @Test func invalidRenameRollsBackAndLeavesTheSavedNoteIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json")
        let state = WorkspacePersonalState(url: url)
        var notebook = StudyDocument(title: "Notebook", kind: .notebook)
        notebook.notes = [StudyNote(title: "Original")]; state.documents = [notebook]; try state.save()
        #expect(throws: (any Error).self) {
            try state.renameNote(notebook.notes[0].id, in: notebook.id, title: String(repeating: "a", count: 4097))
        }
        #expect(state.documents == [notebook])
        #expect(WorkspacePersonalState(url: url).documents == [notebook])
        try state.renameNote(notebook.notes[0].id, in: notebook.id, title: "  ")
        #expect(state.documents == [notebook])
    }
}
