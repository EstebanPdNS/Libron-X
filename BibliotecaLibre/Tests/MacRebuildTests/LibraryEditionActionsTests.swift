import AppKit
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct LibraryEditionActionsTests {
    @Test func visibilityActionsAreReversibleAndRejectAStaleCatalog() async throws {
        let fixture=try AuthoredReaderFixture(documents:[["same"],["same"]]);defer { fixture.remove() }
        let visibility=LibraryResourceVisibility(url:fixture.root.appendingPathComponent("visibility.json"))
        let workspace=StudyWorkspace(personal:.init(url:fixture.root.appendingPathComponent("personal.json")),resourceVisibility:visibility)
        workspace.resources=fixture.resources
        let source=try Data(contentsOf:fixture.resources[0].location)
        let controller=LibraryEditionsController();controller.scan(fixture.resources)
        let deadline=Date().addingTimeInterval(10)
        while controller.isLoading && Date() < deadline { try await Task.sleep(for:.milliseconds(5)) }
        #expect(controller.report != nil && controller.error == nil)
        try controller.setHidden(true,resource:fixture.resources[0],workspace:workspace)
        #expect(visibility.isHidden(fixture.resources[0]))
        try controller.setHidden(false,resource:fixture.resources[0],workspace:workspace)
        #expect(!visibility.isHidden(fixture.resources[0]))
        #expect(try Data(contentsOf:fixture.resources[0].location) == source)
        workspace.resources=[]
        #expect(throws:(any Error).self) { try controller.setHidden(true,resource:fixture.resources[0],workspace:workspace) }
        #expect(!visibility.isHidden(fixture.resources[0]))
    }
    @Test func resourceCitationClipboardMatchesBibliographyStyleAndRetainsUnicode() throws {
        let fixture=try AuthoredReaderFixture(documents:[["source"]]);defer { fixture.remove() }
        let previous=ResourceCitationActions.style;defer { ResourceCitationActions.style=previous }
        ResourceCitationActions.style = .mla
        let board=NSPasteboard.withUniqueName();defer { board.releaseGlobally() }
        let entry=try ResourceCitationActions.entries(fixture.resources)[0]
        ResourceCitationActions.copy(fixture.resources,pasteboard:board)
        #expect(board.string(forType:.string) == ResourceCitation.text(entry,style:.mla,unknown:L("Desconocido")))
        #expect(board.string(forType:.html)?.contains("<i>") == true)
        let before=board.string(forType:.string);ResourceCitationActions.copy([],pasteboard:board)
        #expect(board.string(forType:.string) == before)
    }
}
