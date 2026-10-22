import AppKit
import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct ReaderPersonalNotesTests {
    @Test func selectedExcerptLinksPersistAndReopenTheSameEditableNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: state)
        let resource = LibraryResource(location: URL(fileURLWithPath: "/fixture/notes.LSF"), title: "Fixture", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let text = "Primera frase 🕊️. Segunda frase."
        let range = (text as NSString).range(of: "frase 🕊️")
        let reader = workspace.open(resource, startReading: false)
        reader.page = ReaderPage(destination: .init(ordinal: 2), text: text, sectionCount: 3)
        reader.selectedRange = range
        workspace.addNoteForSelection(reader)
        let link = try #require(state.noteLinks(for: resource).first)
        #expect(link.range == range && link.ordinal == 2)
        let restored = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(restored.noteLinks(for: resource) == [link])
        let matched = ReaderPersonalNoteAttributes.matching([link], text: text, ordinal: 2)
        #expect(matched == [link])
        #expect(ReaderPersonalNoteAttributes.matching([link], text: "Changed " + text, ordinal: 2).isEmpty)
        #expect(ReaderPersonalNoteAttributes.matching([link], text: text, ordinal: 1).isEmpty)
        let display = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 17)])
        ReaderPersonalNoteAttributes.install(matched, in: display)
        #expect(display.string == text)
        #expect(display.attribute(.link, at: range.location, effectiveRange: nil) is URL)
        #expect(display.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(display.attribute(.link, at: 0, effectiveRange: nil) == nil)
        #expect((display.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize == 17)
        workspace.pendingNoteID = nil; workspace.activeTool = nil
        workspace.editPersonalNote(link)
        #expect(workspace.pendingNoteID == link.noteID && state.selectedDocumentID == link.documentID && workspace.activeTool == .documents)
        try state.renameNote(link.noteID, in: link.documentID, title: "Renamed")
        #expect(state.noteLinks(for: resource).first?.title == "Renamed")
        try state.deleteNotes([link.noteID], in: link.documentID)
        #expect(state.noteLinks(for: resource).isEmpty)
        workspace.pendingNoteID = nil; workspace.activeTool = nil; workspace.editPersonalNote(link)
        #expect(workspace.pendingNoteID == nil && workspace.activeTool == nil)
        workspace.closeAll()
    }
    @Test func continuousReaderRemovesTheUnderlineAfterNoteDeletionWithoutChangingText() throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["An authored text with a personal note."]]); defer { fixture.remove() }
        let resource = fixture.resources[0]
        let source = try LegacyContentReader.readSection(lsfURL: resource.location, ordinal: 0)
        let page = ReaderPage(destination: .init(ordinal: 0), text: source.plainText, sectionCount: 1, content: source)
        let reader = ReaderSession(resource: resource)
        reader.page = page; reader.flowPages = [page]
        let state = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: state)
        let range = (page.text as NSString).range(of: "personal note")
        var document = StudyDocument(title: "Notes", kind: .notebook)
        let location = ReaderLocation(resourceID: resource.id, legacyIdentifier: resource.legacyIdentifier, format: resource.format,
            sectionOrdinal: 0, textFingerprint: LibrarySearchService.textFingerprint(page.text))
        document.notes = [StudyNote(title: "My note", anchor: .init(kind: .nativeSelection, location: location,
            selection: .init(location: range.location, length: range.length)))]; state.documents = [document]
        let coordinator = ReaderArticleFlowView.Coordinator(reader: reader, workspace: workspace)
        let scroll = ReaderScrollView(frame: .init(x: 0, y: 0, width: 600, height: 250))
        let flow = ReaderArticleFlowView.FlowDocument(); scroll.documentView = flow
        coordinator.scroll = scroll; coordinator.document = flow
        coordinator.personalNotes = state.noteLinks(for: resource); coordinator.update()
        let view = try #require(coordinator.surfaces[0]?.view)
        #expect(view.string == page.text && view.personalNoteLinks.count == 1)
        #expect(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) is URL)
        state.documents[0].notes = []
        coordinator.personalNotes = state.noteLinks(for: resource); coordinator.update()
        #expect(view.personalNoteLinks.isEmpty && view.string == page.text)
        #expect(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) == nil)
    }
}
