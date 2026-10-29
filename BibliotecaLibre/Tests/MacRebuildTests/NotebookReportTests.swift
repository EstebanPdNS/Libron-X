import AppKit
import LibronixCore
import PDFKit
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
    @Test func rtfdExportPreservesReportText() throws {
        _ = NSApplication.shared
        var document = StudyDocument(title: "Notebook", kind: .notebook)
        var note = StudyNote(title: "First"); note.sourceContentType = "text/plain"; note.sourceBody = "A note"
        document.notes = [note]
        let report = try NotebookReport.make(document: document, selected: [note.id], includeBody: true, includeReferences: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("report.rtfd")
        try ReaderOutputActions.write(report, to: destination, type: "rtfd")
        let restored = try NSAttributedString(url: destination, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        #expect(restored.string == report.string)
    }
    @Test func citationsUseTheExactCatalogEditionAndIndependentOptions() throws {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/books/known.lsf"), title: "Confirmed Book",
            author: "Rivera, Ana", byteCount: 0, format: .legacyLSF, support: .metadataOnly,
            provenance: .legacyPublicMetadata, legacyIdentifier: "BOOK-EDITION-A")
        let location = ReaderLocation(resourceID: resource.id, legacyIdentifier: resource.legacyIdentifier,
            format: resource.format, sectionOrdinal: 0, reference: "John 3:16", textFingerprint: "verified")
        var document = StudyDocument(title: "Report", kind: .notebook)
        var note = StudyNote(title: "Anchored", anchor: .init(kind: .nativeReference, location: location))
        note.sourceContentType = "text/plain"; note.sourceBody = "😀 Comment with λόγος"
        var excluded = StudyNote(title: "Excluded"); excluded.sourceContentType = "text/plain"; excluded.sourceBody = "not selected"
        document.notes = [note, excluded]
        let snapshot = document
        let rendered = try NotebookReport.make(document: document, selected: [note.id], includeBody: true,
            includeReferences: true, includeCitations: true, resources: [resource], citationStyle: .chicagoAuthorDate).string
        #expect(rendered.contains(note.sourceBody) && rendered.contains("John 3:16"))
        #expect(rendered.contains("Rivera, Ana.") && rendered.contains("Confirmed Book.") && rendered.contains("n.d."))
        #expect(!rendered.contains("Excluded") && !rendered.contains("/books/known.lsf"))
        let citationOnly = try NotebookReport.make(document: document, selected: [note.id], includeBody: false,
            includeReferences: false, includeCitations: true, resources: [resource], citationStyle: .mla).string
        #expect(citationOnly.contains("Confirmed Book.") && !citationOnly.contains("n.d."))
        #expect(!citationOnly.contains(note.sourceBody) && !citationOnly.contains("John 3:16"))
        let withoutCitation = try NotebookReport.make(document: document, selected: [note.id], includeBody: true,
            includeReferences: true, includeCitations: false, resources: [resource]).string
        #expect(!withoutCitation.contains("Confirmed Book") && withoutCitation.contains(note.sourceBody))
        #expect(document == snapshot)
    }
    @Test func missingAndAmbiguousSourcesAreExplicitAndNeverReplacedByAnotherEdition() throws {
        let wrong = LibraryResource(location: URL(fileURLWithPath: "/books/replaced.lsf"), title: "Wrong Edition",
            byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .legacyPublicMetadata,
            legacyIdentifier: "B")
        let location = ReaderLocation(resourceID: wrong.id, legacyIdentifier: "A", format: .legacyLSF,
            sectionOrdinal: 0, textFingerprint: "verified")
        var document = StudyDocument(title: "Report", kind: .notebook)
        var note = StudyNote(title: "Original", anchor: .init(kind: .nativeReference, location: location))
        note.sourceContentType = "text/plain"
        var legacy = StudyNote(title: "Legacy", anchor: .init(kind: .legacyReference, legacyAttributes: ["reference": "Jn 3:16"]))
        legacy.sourceContentType = "text/plain"
        document.notes = [note, legacy]
        let report = try NotebookReport.make(document: document, selected: Set(document.notes.map(\.id)), includeBody: false,
            includeReferences: false, includeCitations: true, resources: [wrong]).string
        #expect(!report.contains("Wrong Edition"))
        #expect(report.contains(L("Fuente no disponible en la biblioteca.")))
        #expect(report.contains(L("La fuente original de esta nota no está identificada.")))
        #expect(throws: BibliographyReportError.duplicateIdentity) {
            try NotebookReport.make(document: document, selected: [note.id], includeBody: false,
                includeReferences: false, includeCitations: true, resources: [wrong, wrong])
        }
        let withoutSources = try NotebookReport.make(document: document, selected: [note.id], includeBody: false,
            includeReferences: false, includeCitations: false, resources: [wrong, wrong]).string
        #expect(!withoutSources.contains(L("Fuente no disponible en la biblioteca.")))
        note.anchor.location?.legacyIdentifier = wrong.legacyIdentifier
        note.anchor.location?.format = .libronixLLS
        document.notes = [note]
        let changedFormat = try NotebookReport.make(document: document, selected: [note.id], includeBody: false,
            includeReferences: false, includeCitations: true, resources: [wrong]).string
        #expect(!changedFormat.contains("Wrong Edition") && changedFormat.contains(L("Fuente no disponible en la biblioteca.")))
    }
    @Test func sermonReferenceOptionAlsoControlsMetadataPassages() throws {
        var document = StudyDocument(title: "Sermon", kind: .sermon)
        document.sermon!.speaker = "Speaker"; document.sermon!.passages = ["Jn 3:16"]
        var note = StudyNote(title: "Message"); note.sourceContentType = "text/plain"; note.sourceBody = "Body"
        document.notes = [note]
        let hidden = try NotebookReport.make(document: document, selected: [note.id], includeBody: true, includeReferences: false).string
        let visible = try NotebookReport.make(document: document, selected: [note.id], includeBody: true, includeReferences: true).string
        #expect(hidden.contains("Speaker") && !hidden.contains("Jn 3:16"))
        #expect(visible.contains("Jn 3:16"))
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        let view = ReaderOutputActions.printView(NSAttributedString(string: visible), info: printInfo)
        #expect(view.string == visible && !view.isEditable && view.frame.width > 0 && view.frame.height > 0)
    }

    @Test func shortReportsExportAtTheTopOfThePageWithoutChangingSharedPrintPreferences() throws {
        _ = NSApplication.shared
        let sharedVertical = NSPrintInfo.shared.isVerticallyCentered
        let sharedHorizontal = NSPrintInfo.shared.isHorizontallyCentered
        let info = NotebookReport.printInfo()
        #expect(!info.isVerticallyCentered && !info.isHorizontallyCentered)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        let text = NSAttributedString(string: "Report header\nA short note", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        try ReaderOutputActions.write(text, to: destination, type: "pdf", printInfo: info)
        let pdf = try #require(PDFDocument(url: destination)), page = try #require(pdf.page(at: 0))
        #expect(pdf.pageCount == 1 && pdf.string?.contains("A short note") == true)
        let title = try #require(pdf.findString("Report header", withOptions: []).first)
        #expect(title.bounds(for: page).midY > page.bounds(for: .mediaBox).height * 0.75)
        #expect(NSPrintInfo.shared.isVerticallyCentered == sharedVertical)
        #expect(NSPrintInfo.shared.isHorizontallyCentered == sharedHorizontal)
        #expect(info.jobDisposition != .save)
    }

}
