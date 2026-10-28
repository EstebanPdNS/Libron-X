import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct StudyReferenceExtractionTests {
    @Test func textExtractionKeepsExactUnicodeCoordinatesAndRecognizedReferences() throws {
        let text = "😀 Jn 3:16–18,20; Efesios 5:9. IIICorintios 1:1."
        let report = try StudyReferenceExtraction.text(text, title: "Clipboard")
        #expect(report.complete && report.items.count == 2)
        #expect(report.items.map(\.reference) == ["Jn 3:16–18,20", "Efesios 5:9"])
        for item in report.items {
            #expect((text as NSString).substring(with: item.mention.range.nsRange) == item.mention.label)
            #expect(item.documentDestination == nil)
        }
    }
    @Test func noteLinksKeepTheirTargetAndDocumentChangesInvalidateTheResult() throws {
        var note = StudyNote(title: "Owned")
        note.sourceBody = #"<p>😀 <span lbxrt:xref="bible+esv.64.3.18">18–20</span> and John 3:16</p>"#
        var document = StudyDocument(title: "Owned", kind: .notebook); document.notes = [note]
        let original = document
        let report = try StudyReferenceExtraction.document(document)
        #expect(report.items.count == 2 && report.complete)
        #expect(report.items[0].reference == "bible+esv.64.3.18")
        #expect(report.items[0].mention.origin == .explicitLink && report.items[1].reference == "John 3:16")
        try report.validate(against: [document])
        #expect(document == original)
        document.notes[0].sourceBody += " changed"
        #expect(throws: PersonalStateError.self) { try report.validate(against: [document]) }
    }
    @Test func malformedEditsRemainExplicitlyPartial() throws {
        var note = StudyNote(title: "Owned"); note.sourceBody = "<p>Jn 3:16</p>"; note.editedRTF = Data("invalid".utf8)
        var document = StudyDocument(title: "Owned", kind: .notebook); document.notes = [note]
        let report = try StudyReferenceExtraction.document(document)
        #expect(!report.complete && !report.warnings.isEmpty && report.items.map(\.reference) == ["Jn 3:16"])
        #expect(note.editedRTF == Data("invalid".utf8))
    }
    @Test func legacyLinkTargetsRetainTheirEditionAndCanBeAddedAtomically() throws {
        let text = "Verse 18"
        let range = (text as NSString).range(of: "18")
        let report = try StudyReferenceExtraction.text(text,
            links: [.init(range: .init(location: range.location, length: range.length), target: "=rJn3:18(ESV)")], title: "Owned")
        let entry = try #require(report.items.first)
        #expect(entry.mention.label == "18" && entry.mention.citation.edition == "esv")
        #expect(try BibleReferenceQuery.parse(entry.reference).citations == [entry.mention.citation])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        let list = StudyDocument(title: "Owned list", kind: .verseList)
        state.documents = [list]; try state.save()
        try state.appendExtractedReferences([entry.reference], to: list.id)
        let before = try Data(contentsOf: root.appendingPathComponent("personal.json"))
        #expect(throws: (any Error).self) { try state.appendExtractedReferences(["not a reference"], to: list.id) }
        #expect(state.documents[0].verses.map(\.reference) == [entry.reference])
        #expect(try Data(contentsOf: root.appendingPathComponent("personal.json")) == before)
        #expect(WorkspacePersonalState(url: root.appendingPathComponent("personal.json")).documents[0].verses.map(\.reference) == [entry.reference])
    }
}
