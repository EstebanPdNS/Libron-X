import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct WindowCommandsTests {
    private func workspace() -> StudyWorkspace {
        StudyWorkspace(personal: WorkspacePersonalState(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("libronx-windows-\(UUID()).json")))
    }
    private func resource() -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/authored/duplicate.LSF"), title: "Same title", byteCount: 0,
              format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
    }
    @Test func twelveIdenticalTitlesKeepOpeningOrderWhileActivationChangesStacking() {
        let workspace = workspace()
        let readers = (0..<12).map { _ in workspace.open(resource(), startReading: false) }
        workspace.activate(readers[1]); workspace.activate(readers[8])
        let selection = WorkspaceWindowSelection(workspace: workspace)
        #expect(selection.readers.map(\.id) == readers.map(\.id))
        #expect(selection.selectedID == readers[8].id)
        selection.selectedID = readers[0].id
        #expect(workspace.activeID == readers[8].id)
        workspace.activeTool = .windows
        #expect(selection.activateSelected())
        #expect(workspace.activeReader === readers[0] && workspace.activeTool == nil)
        #expect(workspace.readers.last === readers[0])
        #expect(selection.readers.map(\.id) == readers.map(\.id))
    }
    @Test func activateRestoresMinimizedReaderAndLeavesHomeWithoutChangingReferenceDraft() {
        let workspace = workspace()
        let first = workspace.open(resource(), startReading: false)
        let second = workspace.open(resource(), startReading: false)
        first.locator = "Gen 4.12"
        workspace.minimize(first); workspace.showsHome = true; workspace.activeTool = .windows
        let selection = WorkspaceWindowSelection(workspace: workspace)
        selection.selectedID = first.id
        #expect(workspace.activeReader === second && first.isMinimized)
        #expect(selection.activateSelected())
        #expect(!first.isMinimized && !workspace.showsHome && first.locator == "Gen 4.12")
        #expect(workspace.activeReader === first && workspace.activeTool == nil)
    }
    @Test func closingSelectionRetainsUnrelatedPaneAndClearsReferenceTargetThenSelectsNeighbor() {
        let workspace = workspace()
        let readers = (0..<3).map { _ in workspace.open(resource(), startReading: false) }
        readers[0].locator = "Unsaved reference draft"
        workspace.referenceTargetID = readers[1].id; workspace.activeTool = .windows
        let selection = WorkspaceWindowSelection(workspace: workspace)
        selection.selectedID = readers[1].id
        #expect(selection.closeSelected())
        #expect(selection.selectedID == readers[2].id && workspace.referenceTargetID == nil)
        #expect(workspace.activeReader === readers[2] && workspace.activeTool == .windows)
        #expect(readers[0].locator == "Unsaved reference draft")
        #expect(selection.closeSelected() && selection.selectedID == readers[0].id)
        #expect(selection.closeSelected() && selection.selectedID == nil)
        #expect(workspace.readers.isEmpty && workspace.activeID == nil)
        #expect(!selection.closeSelected() && !selection.activateSelected())
    }
    @Test func externallyClosedSelectionCannotActivateOrCloseAnUnrelatedReader() {
        let workspace = workspace()
        let first = workspace.open(resource(), startReading: false)
        let second = workspace.open(resource(), startReading: false)
        let selection = WorkspaceWindowSelection(workspace: workspace)
        selection.selectedID = first.id; workspace.close(first); workspace.activeTool = .windows
        #expect(!selection.activateSelected() && !selection.closeSelected())
        #expect(workspace.readers.map(\.id) == [second.id] && workspace.activeTool == .windows)
        selection.reconcile()
        #expect(selection.selectedID == second.id)
        workspace.closeAll(); selection.reconcile()
        #expect(selection.selectedID == nil)
    }
    @Test func cyclingUsesOpeningOrderWrapsInBothDirectionsAndRestoresMinimizedReaders() {
        let workspace = workspace()
        let readers = (0..<4).map { _ in workspace.open(resource(), startReading: false) }
        workspace.activate(readers[1]); workspace.minimize(readers[2])
        workspace.cycleReader()
        #expect(workspace.activeReader === readers[2] && !readers[2].isMinimized)
        workspace.cycleReader(backwards: true); #expect(workspace.activeReader === readers[1])
        workspace.activate(readers[0]); workspace.cycleReader(backwards: true)
        #expect(workspace.activeReader === readers[3])
        workspace.cycleReader(); #expect(workspace.activeReader === readers[0])
        workspace.activeID = nil; workspace.cycleReader(); #expect(workspace.activeReader === readers[0])
        workspace.activeID = nil; workspace.cycleReader(backwards: true); #expect(workspace.activeReader === readers[3])
        workspace.closeAll(); workspace.cycleReader(); #expect(workspace.activeReader == nil)
    }
}
