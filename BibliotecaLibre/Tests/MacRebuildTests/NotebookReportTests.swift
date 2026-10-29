import AppKit
import LibronixCore
import Testing
@testable import MacRebuild

@Suite(.serialized) @MainActor struct NotebookReportTests {
    @Test func selectionOptionsAndEditedTextAreHonored() throws {
        _ = NSApplication.shared
        var document = StudyDocument(title: "Notebook", kind: .notebook)
        var first = StudyNote(title: "First", anchor: .init(kind: .legacyReference, legacyAttributes: ["reference": "John 3:16"]))
        first.sourceContentType = "text/plain"; first.sourceBody = "old text"
        first.editedRTF = try NoteRichTextCodec.encode(NSAttributedString(string: "edited text"))
        var second = StudyNote(title: "Second"); second.sourceContentType = "text/plain"; second.sourceBody = "other"
        document.notes = [first, second]
        let all = try NotebookReport.make(document: document, selected: [first.id], includeBody: true, includeReferences: true).string
        #expect(all.contains("First") && all.contains("John 3:16") && all.contains("edited text"))
        #expect(!all.contains("old text") && !all.contains("Second"))
        let titles = try NotebookReport.make(document: document, selected: [first.id], includeBody: false, includeReferences: false).string
        #expect(!titles.contains("edited text") && !titles.contains("John 3:16"))
        #expect(throws: (any Error).self) { try NotebookReport.make(document: document, selected: [UUID()], includeBody: true, includeReferences: true) }
    }
    @Test func unsupportedObjectsAreNotSilentlyDiscarded() throws {
        var document = StudyDocument(title: "Notebook", kind: .notebook)
        var note = StudyNote(title: "Illustrated"); note.sourceBody = "<p>text</p><img src='image.png'>"
        document.notes = [note]
        #expect(throws: (any Error).self) { try NotebookReport.make(document: document, selected: [note.id], includeBody: true, includeReferences: true) }
        _ = try NotebookReport.make(document: document, selected: [note.id], includeBody: false, includeReferences: true)
    }
    @Test func invalidEditedTextFailsInsteadOfExportingStaleSource() throws {
        var document = StudyDocument(title: "Notebook", kind: .notebook)
        var note = StudyNote(title: "Changed"); note.sourceBody = "stale"; note.editedRTF = Data("broken".utf8)
        document.notes = [note]
        #expect(throws: (any Error).self) { try NotebookReport.make(document: document, selected: [note.id], includeBody: true, includeReferences: true) }
    }
}
