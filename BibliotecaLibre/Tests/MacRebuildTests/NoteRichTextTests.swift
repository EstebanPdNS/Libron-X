import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct NoteRichTextTests {
    private func editor(_ note: StudyNote, changed: @escaping (Data) -> Void = { _ in }) -> (NSWindow, NSTextView, NoteEditorController) {
        _ = NSApplication.shared
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.isRichText = true; view.allowsUndo = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let controller = NoteEditorController(); view.delegate = controller
        controller.configure(note, editor: view, changed: changed)
        return (window, view, controller)
    }

    @Test func inertHTMLAndRTFRoundTripPreserveFormattingLinksListsAndOriginal() throws {
        var note = StudyNote(title: "Owned rich note")
        note.sourceBody = #"<p><b>😀 Alpha</b> <i>café</i> <u>שלום</u> <del>removed</del> <span lbxrt:xref="bible+esv.64.3.18">18–20</span> <a href="https://example.invalid/owned">web</a></p><ol start="3"><li>First</li><li>Second</li></ol><script>not visible</script>"#
        let original = note
        let text = try NoteRichTextCodec.attributed(note)
        #expect(text.string == "😀 Alpha café שלום removed 18–20 web\n3. First\n4. Second\n")
        let strong = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(strong.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        let deletedRange = (text.string as NSString).range(of: "removed")
        #expect((text.attribute(.strikethroughStyle, at: deletedRange.location, effectiveRange: nil) as? NSNumber)?.intValue != 0)
        let data = try NoteRichTextCodec.encode(text)
        note.editedRTF = data
        let reopened = try NoteRichTextCodec.attributed(note)
        #expect(reopened.string == text.string)
        #expect((reopened.attribute(.strikethroughStyle, at: deletedRange.location, effectiveRange: nil) as? NSNumber)?.intValue != 0)
        let reopenedFont = reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(reopenedFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        #expect((reopened.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .textColor)
        let projected = PersonalReferenceProjection.body(note)
        #expect(projected.text == text.string && projected.links.count == 1)
        let range = (text.string as NSString).range(of: "18–20")
        #expect(projected.links[0].range.nsRange == range && projected.links[0].target == "bible+esv.64.3.18")
        #expect(note.sourceBody == original.sourceBody && note.sourceAttributes == original.sourceAttributes && note.anchor == original.anchor)
        let unsafe = NoteRichTextCodec.webURL("javascript:alert(1)")
        #expect(unsafe == nil && NoteRichTextCodec.webURL("file:///private/owned") == nil)
    }

    @Test func titleSearchTargetPreservesUnicodeAndRejectsStaleOrWrongNote() throws {
        let id = UUID(), title = "😀 Café y estudio", match = (title as NSString).range(of: "Café")
        let target = BibleReferencePersonalDestination(documentID: UUID(), entryID: id, field: .noteTitle,
            textSHA256: LibrarySearchService.textFingerprint(title), projectionSHA256: "unused",
            range: .init(location: match.location, length: match.length))
        let range = try #require(StudyNoteTitleSearchTarget.range(target, noteID: id, title: title))
        #expect(String(title[range]) == "Café")
        #expect(StudyNoteTitleSearchTarget.range(target, noteID: id, title: title + " edited") == nil)
        #expect(StudyNoteTitleSearchTarget.range(target, noteID: UUID(), title: title) == nil)
        let fieldEditor = NSTextView(); fieldEditor.isFieldEditor = true; fieldEditor.string = title
        #expect(StudyNoteTitleSearchTarget.apply(target, noteID: id, title: title, editor: fieldEditor))
        #expect(fieldEditor.selectedRange() == match)
        fieldEditor.string = title + " changed"
        #expect(!StudyNoteTitleSearchTarget.apply(target, noteID: id, title: title, editor: fieldEditor))
    }

    @Test func searchSelectionRequiresUnchangedEditorTextAndDoesNotOverrideUserSelection() throws {
        var note = StudyNote(title: "Owned"); note.sourceContentType = "text/plain"; note.sourceBody = "😀 Alpha café"
        let (window, view, controller) = editor(note); defer { window.close() }
        let text = view.string, range = (text as NSString).range(of: "café")
        let destination = BibleReferencePersonalDestination(documentID: UUID(), entryID: note.id, field: .noteBody,
            textSHA256: LibrarySearchService.textFingerprint(text), projectionSHA256: "unused",
            range: .init(location: range.location, length: range.length))
        let token = UUID(); controller.selectSearchResult(destination, navigationID: token, editor: view)
        #expect(view.selectedRange() == range)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        controller.selectSearchResult(destination, navigationID: token, editor: view)
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
        view.textStorage?.replaceCharacters(in: range, with: "changed")
        controller.selectSearchResult(destination, navigationID: UUID(), editor: view)
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func nativeFormattingUndoRedoAndListsKeepUnicodeAndLinkCoordinates() throws {
        var note = StudyNote(); note.sourceContentType = "text/plain"; note.sourceBody = "😀 John3:16\nSecond"
        var saved: Data?
        let (window, view, controller) = editor(note) { saved = $0 }
        defer { window.close() }
        let range = (view.string as NSString).range(of: "John3:16")
        view.setSelectedRange(range); controller.refresh()
        controller.toggleFont(.boldFontMask)
        #expect(controller.canUndo && controller.isBold && saved != nil)
        controller.undo(); #expect(!controller.isBold && controller.canRedo)
        controller.redo(); #expect(controller.isBold)
        controller.setLink("John3:16")
        let linked = try NoteRichTextCodec.projection(#require(saved))
        #expect(linked.links.first?.range.nsRange == range)
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count)); controller.refresh()
        controller.list(numbered: false)
        #expect(view.string == "• 😀 John3:16\n• Second")
        let list = try NoteRichTextCodec.projection(#require(saved))
        #expect(list.links.first?.range.location == range.location + 2)
        controller.undo(); #expect(view.string == note.sourceBody)
        controller.redo(); #expect(view.string.hasPrefix("• 😀"))
    }

    @Test func changingNotesClearsUndoAndMalformedEditsRemainReadOnly() throws {
        var first = StudyNote(); first.sourceContentType = "text/plain"; first.sourceBody = "First"
        let (window, view, controller) = editor(first)
        defer { window.close() }
        view.setSelectedRange(NSRange(location: 0, length: 5)); controller.refresh(); controller.toggleUnderline()
        #expect(controller.canUndo)
        var second = StudyNote(); second.sourceContentType = "text/plain"; second.sourceBody = "Second"
        controller.configure(second, editor: view) { _ in Issue.record("Unexpected change during configuration") }
        #expect(view.string == "Second" && !controller.canUndo && view.selectedRange().length == 0)
        second.editedRTF = Data("invalid saved bytes".utf8)
        controller.configure(second, editor: view) { _ in Issue.record("Malformed data was overwritten") }
        #expect(controller.readOnly && !view.isEditable && controller.error != nil)
        controller.list(numbered: true); controller.toggleFont(.boldFontMask)
        #expect(view.string == "Second" && second.editedRTF == Data("invalid saved bytes".utf8))
    }

    @Test func nativeEditsSaveReopenAndReplaceSearchProjectionWithoutRewritingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try StudyDocument.importingLegacyXML(Data(#"<lbx-annotations name="Owned"><annotation guid="owned"><title>Title</title><content type="text/html"><![CDATA[<p>John3:99</p>]]></content></annotation></lbx-annotations>"#.utf8), sourceSHA256: "owned-hash")
        let original = document, state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        state.documents = [document]
        let rich = NSMutableAttributedString(string: "😀 Edited John3:16", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        let data = try NoteRichTextCodec.encode(rich)
        try state.updateNoteRichText(document.notes[0].id, in: document.id, data: data); try state.save()
        document = try #require(WorkspacePersonalState(url: root.appendingPathComponent("personal.json")).documents.first)
        #expect(document.schemaVersion == 2)
        #expect(document.sourceXML == original.sourceXML && document.sourceSHA256 == original.sourceSHA256)
        #expect(document.notes[0].sourceBody == original.notes[0].sourceBody && document.notes[0].sourceAttributes == original.notes[0].sourceAttributes)
        #expect(document.notes[0].id == original.notes[0].id && document.notes[0].editedRTF == data)
        let projection = try PersonalReferenceProjection.source(document)
        #expect(projection.projectionComplete && projection.warnings.isEmpty)
        #expect(projection.fields.first { $0.kind == .noteBody }?.text == rich.string)
    }
    @Test func importedSuperscriptAndSubscriptRemainEditable() throws {
        var note = StudyNote(title: "Owned")
        note.sourceBody = "Water H<sub>2</sub>O and x<sup>2</sup>"
        let text = try NoteRichTextCodec.attributed(note)
        let sub = (text.string as NSString).range(of: "2")
        let sup = (text.string as NSString).range(of: "2", options: .backwards)
        #expect((text.attribute(.superscript, at: sub.location, effectiveRange: nil) as? NSNumber)?.intValue == -1)
        #expect((text.attribute(.superscript, at: sup.location, effectiveRange: nil) as? NSNumber)?.intValue == 1)
        let reopened = try NoteRichTextCodec.decode(NoteRichTextCodec.encode(text))
        #expect(reopened.string == text.string && note.sourceBody.contains("<sub>"))
        #expect((reopened.attribute(.superscript, at: sub.location, effectiveRange: nil) as? NSNumber)?.intValue == -1)
        #expect((reopened.attribute(.superscript, at: sup.location, effectiveRange: nil) as? NSNumber)?.intValue == 1)
    }

}
