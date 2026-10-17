import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ReaderStudyActionsTests {
    @Test func bibleFooterFollowsTheVisibleReferenceAndKeepsArticlePosition() throws {
        let fixture = try AuthoredReaderFixture(documents: [["text"]]); defer { fixture.remove() }
        let original = fixture.resources[0]
        var metadata = LibronMetadata(title: "Bible", origin: "e-Sword")
        metadata.resourceType = "Biblia"
        let resource = LibraryResource(location: original.location, title: "Bible", byteCount: 0,
            format: original.format, support: original.support, provenance: original.provenance, libron: metadata)
        let reader = ReaderSession(resource: resource)
        reader.page = ReaderPage(destination: .init(ordinal: 4, reference: "Mt 9:36"), text: "text", sectionCount: 12)
        #expect(reader.readingPositionLabel(language: .spanish) == "Mt 9:36 · Artículo 5 de 12")
        reader.visibleBibleReference = "Mt 9:37"
        #expect(reader.readingPositionLabel(language: .spanish) == "Mt 9:37 · Artículo 5 de 12")
        let book = ReaderSession(resource: original)
        book.page = ReaderPage(destination: .init(ordinal: 4), text: "text", sectionCount: 12)
        #expect(book.readingPositionLabel(language: .spanish) == "Artículo 5 de 12")
    }
    @Test func paletteAndSelectionNotesPersistWithoutModifyingTheBook() throws {
        let fixture = try AuthoredReaderFixture(documents: [["palabra elegida texto"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("personal.json")
        let workspace = StudyWorkspace(personal: WorkspacePersonalState(url: url),
            resourceVisibility: .init(url: fixture.root.appendingPathComponent("hidden.json")))
        defer { workspace.shutdown() }
        let before = try Data(contentsOf: fixture.resources[0].location)
        let first = workspace.open(fixture.resources[0], startReading: false)
        let second = workspace.open(fixture.resources[0], startReading: false)
        let page = ReaderPage(destination: .init(ordinal: 0, reference: "Ge 1:1"), text: "palabra elegida texto", sectionCount: 1)
        first.page = page; second.page = page
        first.selectedRange = NSRange(location: 0, length: 7)
        workspace.activate(first)
        for color in ["yellow", "green", "blue", "pink"] { workspace.addHighlight(color) }
        #expect(workspace.personal.highlights.count == 4)
        #expect(first.highlights.count == 4 && second.highlights.count == 4)
        #expect(WorkspacePersonalState(url: url).highlights.count == 4)
        workspace.eraseHighlight()
        #expect(workspace.personal.highlights.isEmpty && first.highlights.isEmpty && second.highlights.isEmpty)
        #expect(WorkspacePersonalState(url: url).highlights.isEmpty)
        second.selectedRange = NSRange(location: 8, length: 7)
        workspace.addNoteForSelection(second)
        let note = try #require(workspace.personal.documents.first?.notes.last)
        #expect(note.sourceBody == "elegida")
        #expect(note.effectiveAnchor.location?.resourceID == second.resource.id)
        #expect(workspace.pendingNoteID == note.id && workspace.activeTool == .documents)
        #expect(WorkspacePersonalState(url: url).documents.first?.notes.last?.id == note.id)
        #expect(try Data(contentsOf: fixture.resources[0].location) == before)
    }
}
