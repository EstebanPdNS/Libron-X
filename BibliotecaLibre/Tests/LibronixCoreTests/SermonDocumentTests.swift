import Foundation
import Testing
@testable import LibronixCore

struct SermonDocumentTests {
    @Test func sermonRoundTripKeepsDetailsNotesAndOriginalProvenance() throws {
        var document = StudyDocument(title: "Fe y esperanza", kind: .sermon)
        document.sermon!.speaker = "Ana"; document.sermon!.series = "Romanos"
        document.sermon!.venue = "Comunidad"; document.sermon!.passages = ["Jn 3:16", "Romanos 8:1"]
        document.sermon!.tags = ["fe", "esperanza"]
        document.sermon!.preachedOn = try ReadingDay(year: 2026, month: 10, day: 29)
        var note = StudyNote(title: "Introducción"); note.sourceBody = "<p>😀 Esperanza</p>"
        document.notes = [note]; document.sourceSHA256 = "original-source"
        try document.validate()
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(StudyDocument.self, from: encoded)
        try decoded.validate()
        #expect(decoded == document && decoded.schemaVersion == 3 && decoded.kind.usesNotes)
        #expect(decoded.sermon?.dateText == "2026-10-29")
        let legacy = StudyDocument(title: "Old", kind: .notebook)
        let oldData = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: oldData, as: UTF8.self).contains("sermon"))
        #expect(try JSONDecoder().decode(StudyDocument.self, from: oldData) == legacy)
    }
    @Test func invalidSchemaMetadataDateAndPassagesAreRejected() throws {
        var document = StudyDocument(title: "Owned", kind: .sermon)
        document.schemaVersion = 2
        #expect(throws: PersonalStateError.self) { try document.validate() }
        document.schemaVersion = 3; document.sermon = nil
        #expect(throws: PersonalStateError.self) { try document.validate() }
        document.sermon = SermonMetadata(); document.sermon!.passages = ["not a reference"]
        #expect(throws: (any Error).self) { try document.validate() }
        document.sermon!.passages = []; document.sermon!.tags = ["duplicate", "duplicate"]
        #expect(throws: PersonalStateError.self) { try document.validate() }
        document.sermon!.tags = []; document.sermon!.speaker = "a\0b"
        #expect(throws: PersonalStateError.self) { try document.validate() }
        document.sermon!.speaker = ""; document.kind = .notebook
        #expect(throws: PersonalStateError.self) { try document.validate() }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(StudyDocument(title: "Date", kind: .sermon))) as? [String: Any])
        object["sermon"] = ["speaker": "", "series": "", "venue": "", "tags": [], "passages": [], "preachedOn": ["year": 2026, "month": 2, "day": 30]]
        let invalid = try JSONDecoder().decode(StudyDocument.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: PersonalStateError.self) { try invalid.validate() }
        var future = StudyDocument(title: "Future", kind: .sermon); future.schemaVersion = 4
        #expect(throws: PersonalStateError.self) { try future.validate() }
    }
    @Test func noteOrganizationPreservesSermonVersionAndMetadata() throws {
        var sermon = StudyDocument(title: "Sermon", kind: .sermon)
        sermon.sermon!.series = "Series"
        let parent = StudyNote(title: "Parent")
        var child = StudyNote(title: "Child"); child.parentID = parent.id
        sermon.notes = [parent, child]
        let duplicate = try StudyNoteOrganization.duplicating([parent.id], in: sermon, titleSuffix: "copy")
        #expect(duplicate.schemaVersion == 3 && duplicate.sermon == sermon.sermon && duplicate.notes.count == 4)
        let deleted = try StudyNoteOrganization.deleting([parent.id], from: sermon)
        #expect(deleted.schemaVersion == 3 && deleted.notes[0].parentID == nil && deleted.sermon == sermon.sermon)
        let notebook = StudyDocument(title: "Notebook", kind: .notebook)
        let moved = try StudyNoteOrganization.moving([parent.id], from: sermon.id, to: notebook.id, documents: [sermon, notebook])
        #expect(moved[0].schemaVersion == 3 && moved[0].sermon == sermon.sermon && moved[0].notes.isEmpty)
        #expect(moved[1].schemaVersion == 2 && moved[1].notes.count == 2 && moved[1].notes[0].origin?.documentID == sermon.id)
    }
}
