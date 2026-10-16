import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LibronixCore
@testable import BibliotecaMac

@MainActor @Suite struct StudyDocumentsTests {
    @Test func notebookChangesSaveAndReopenWithOriginalImportAndNativeRTFSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyDocumentsStore(directory: root)
        let data = Data(#"<lbx-annotations name="Own imported notebook"><annotation author="Own"><title>Original</title><content type="text/html"><![CDATA[<P><STRONG>Alpha</STRONG></P>]]></content></annotation></lbx-annotations>"#.utf8)
        let original = try StudyDocument.importingLegacyXML(data), id = try store.insert(original)
        let note = try #require(original.notes.first)
        let native = NSMutableAttributedString(string: "שלום — edited 🦉", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        let rtf = try native.data(from: NSRange(location: 0, length: native.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        store.changeNote(id, noteID: note.id) { $0.title = "Own edited title"; $0.editedRTF = rtf }
        #expect(store.unsavedIDs.contains(id)); store.flush(); #expect(store.unsavedIDs.isEmpty)
        let reopened = StudyDocumentsStore(directory: root), document = try #require(reopened.document(id))
        #expect(document.sourceXML == original.sourceXML)
        #expect(document.notes[0].sourceBody == note.sourceBody && document.notes[0].sourceAttributes["author"] == "Own")
        #expect(document.notes[0].title == "Own edited title")
        let displayed = NoteRichTextEditor.attributed(document.notes[0])
        #expect(displayed.string == native.string)
        let font = try #require(displayed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }
    @Test func nativeEditorAllowsRichEditingAndPreservesItsInitialImportedSource() async throws {
        var note = StudyNote(); note.sourceBody = "<P><STRONG>Own alpha</STRONG></P>"
        var edits: [Data] = []
        let hosting = NSHostingView(rootView: NoteRichTextEditor(note: note) { edits.append($0) })
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let editor = try #require(textView(hosting))
        #expect(editor.isEditable && editor.isRichText && editor.allowsUndo)
        #expect(editor.string == "Own alpha\n")
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        editor.insertText("Edited", replacementRange: editor.selectedRange())
        let data = try #require(edits.last), result = try #require(NSAttributedString(rtf: data, documentAttributes: nil))
        #expect(result.string == "Edited alpha\n")
        #expect(note.sourceBody == "<P><STRONG>Own alpha</STRONG></P>")
    }
    @Test func independentlyEditedNotesInTwoWindowsDoNotOverwriteOtherEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyDocumentsStore(directory: root), first = StudyNote(title: "First"), second = StudyNote(title: "Second")
        var doc = StudyDocument(title: "Shared", kind: .notebook); doc.notes = [first, second]
        let id = try store.insert(doc)
        store.changeNote(id, noteID: first.id) { $0.title = "First edited" }
        store.changeNote(id, noteID: second.id) { $0.title = "Second edited" }
        store.flush()
        #expect(StudyDocumentsStore(directory: root).document(id)?.notes.map(\.title) == ["First edited", "Second edited"])
    }
    @Test func verseListPresentationAndInputOrderSurviveSaveReopenAndReorder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyDocumentsStore(directory: root)
        var doc = StudyDocument(title: "Own list", kind: .verseList)
        doc.verses = [StudyVerseEntry(reference: "bible.64.1.1-64.1.2"), StudyVerseEntry(reference: "bible.1.1.1")]
        doc.presentation = "BothTwoColumns"; doc.referenceAttributes = ["type1":"LLS:1.0.3", "type2":"LLS:1.0.71"]
        let id = try store.insert(doc)
        store.change(id) { $0.verses.reverse() }; store.flush()
        let reloaded = try #require(StudyDocumentsStore(directory: root).document(id))
        #expect(reloaded.verses.map(\.reference) == ["bible.1.1.1", "bible.64.1.1-64.1.2"])
        #expect(reloaded.presentation == "BothTwoColumns" && reloaded.referenceAttributes == doc.referenceAttributes)
    }
    private func textView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.compactMap(textView).first
    }
}
