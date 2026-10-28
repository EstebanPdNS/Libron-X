import Foundation
import Testing
@testable import LibronixCore

struct StudyNoteOrganizationTests {
    private func notebook() -> StudyDocument {
        var document = StudyDocument(title: "Owned notebook", kind: .notebook); document.schemaVersion = 2
        var a = StudyNote(title: "John", anchor: .init(kind: .legacyReference, legacyAttributes: ["reference": "John3:16"]))
        a.sourceBody = "<b>😀 Original</b>"; a.editedRTF = Data("owned test edit".utf8)
        var child = StudyNote(title: "Child"); child.parentID = a.id
        var grandchild = StudyNote(title: "Grandchild"); grandchild.parentID = child.id
        let b = StudyNote(title: "Genesis", anchor: .init(kind: .legacyReference, legacyAttributes: ["reference": "Gen1:1"]))
        document.notes = [a, child, grandchild, b]; document.sourceSHA256 = "owned-source"
        return document
    }

    @Test func movingSubtreesAcrossNotebooksKeepsIDsContentAnchorsAndProvenance() throws {
        let source = notebook()
        var destination = StudyDocument(title: "Destination", kind: .notebook)
        let parent = StudyNote(title: "Parent"); destination.notes = [parent]
        let moved = try StudyNoteOrganization.moving([source.notes[0].id], from: source.id, to: destination.id,
            parentID: parent.id, documents: [source, destination])
        #expect(moved[0].notes.map(\.id) == [source.notes[3].id])
        #expect(moved[1].notes.map(\.id) == [parent.id] + source.notes.prefix(3).map(\.id))
        #expect(try StudyNoteOrganization.outline(moved[1].notes).map(\.depth) == [0,1,2,3])
        #expect(moved[1].notes[1].sourceBody == source.notes[0].sourceBody && moved[1].notes[1].editedRTF == source.notes[0].editedRTF)
        #expect(moved[1].notes[1].anchor == source.notes[0].anchor && moved[1].notes[1].origin?.documentID == source.id)
        #expect(moved[1].notes[1].origin?.sourceSHA256 == source.sourceSHA256)
        #expect(moved.allSatisfy { $0.schemaVersion == 2 })
        #expect(try JSONDecoder().decode([StudyDocument].self, from: JSONEncoder().encode(moved)) == moved)
        #expect(source.notes.count == 4 && destination.notes.count == 1)
    }

    @Test func invalidDestinationsCyclesOrExcessiveDepthRejectWithoutChangingInputs() throws {
        let source = notebook(), original = try JSONEncoder().encode(notebook())
        #expect(throws: PersonalStateError.self) {
            try StudyNoteOrganization.moving([source.notes[0].id], from: source.id, to: source.id,
                parentID: source.notes[1].id, documents: [source])
        }
        var cycle = source; cycle.notes[0].parentID = cycle.notes[2].id
        #expect(throws: PersonalStateError.self) { try cycle.validate() }
        var missing = source; missing.notes[0].parentID = UUID()
        #expect(throws: PersonalStateError.self) { try missing.validate() }
        var deep = StudyDocument(title: "Deep", kind: .notebook); deep.schemaVersion = 2
        for _ in 0..<66 { var note = StudyNote(); note.parentID = deep.notes.last?.id; deep.notes.append(note) }
        #expect(throws: PersonalStateError.self) { try deep.validate() }
        #expect(!original.isEmpty && source.notes.count == 4)
    }

    @Test func duplicationRekeysOnlyCopiesAndDeletionPromotesSurvivingChildren() throws {
        let source = notebook()
        let duplicated = try StudyNoteOrganization.duplicating([source.notes[0].id, source.notes[1].id], in: source, titleSuffix: "Copy")
        #expect(duplicated.notes.count == 7 && Set(duplicated.notes.map(\.id)).count == 7)
        let copies = Array(duplicated.notes.suffix(3))
        #expect(copies[1].parentID == copies[0].id && copies[2].parentID == copies[1].id)
        #expect(copies[0].sourceBody == source.notes[0].sourceBody && copies[0].editedRTF == source.notes[0].editedRTF)
        #expect(copies[0].origin?.noteID == source.notes[0].id)
        let deleted = try StudyNoteOrganization.deleting([source.notes[0].id], from: source)
        #expect(deleted.notes.count == 3 && deleted.notes[0].id == source.notes[1].id && deleted.notes[0].parentID == nil)
        #expect(deleted.notes[1].parentID == deleted.notes[0].id)
        let both = try StudyNoteOrganization.deleting([source.notes[0].id, source.notes[1].id], from: source)
        #expect(both.notes.first?.id == source.notes[2].id && both.notes.first?.parentID == nil)
    }

    @Test func referenceAndDateSortingKeepHierarchyAndLegacyDocumentsRemainReadable() throws {
        var source = notebook()
        source.notes[0].modifiedUTC = "2025-01-01T01:00:00+02:00"
        source.notes[3].modifiedUTC = "2024-12-31T23:30:00Z"
        let referenced = try StudyNoteOrganization.sorting(source, by: .reference)
        #expect(referenced.notes.map(\.id) == [source.notes[3].id, source.notes[0].id, source.notes[1].id, source.notes[2].id])
        let dated = try StudyNoteOrganization.sorting(source, by: .modified)
        #expect(dated.notes.first?.id == source.notes[3].id)
        var old = StudyDocument(title: "Version 1", kind: .notebook); old.notes = [StudyNote(title: "Old")]
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(StudyDocument.self, from: data)
        try decoded.validate(); #expect(decoded.schemaVersion == 1 && decoded.notes[0].parentID == nil && decoded.notes[0].properties == nil)
        old.notes[0].parentID = UUID()
        #expect(throws: PersonalStateError.self) { try old.validate() }
    }
}
