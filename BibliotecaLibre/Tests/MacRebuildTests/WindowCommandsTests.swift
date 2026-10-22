import Foundation
import AppKit
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct WindowCommandsTests {
    @Test func closingTheActivePaneSelectsItsOpeningSuccessorAndRestoresMinimizedPanes() {
        let workspace = workspace()
        let readers = (0..<3).map { _ in workspace.open(resource(), startReading: false) }
        workspace.activate(readers[1]); workspace.minimize(readers[2]); workspace.activate(readers[1])
        workspace.close(readers[1])
        #expect(workspace.activeReader === readers[2] && !readers[2].isMinimized)
        workspace.close(readers[2]); #expect(workspace.activeReader === readers[0])
        workspace.close(readers[0]); #expect(workspace.activeReader == nil && workspace.readers.isEmpty)
    }
    @Test func closeShortcutAcceptsCommandWWithoutStealingOtherWindowShortcuts() throws {
        func event(_ flags: NSEvent.ModifierFlags, _ characters: String = "w") throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 13))
        }
        #expect(BibleVersionKeyboardRouting.KeyView.isCloseReadingShortcut(try event(.command)))
        #expect(BibleVersionKeyboardRouting.KeyView.isCloseReadingShortcut(try event([.command, .capsLock], "W")))
        for flags: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            #expect(!BibleVersionKeyboardRouting.KeyView.isCloseReadingShortcut(try event(flags)))
        }
        #expect(!BibleVersionKeyboardRouting.KeyView.isCloseReadingShortcut(try event(.command, "t")))
    }
    @Test func findShortcutKeepsGlobalSearchAndOtherModifiedKeysDistinct() throws {
        func event(_ flags: NSEvent.ModifierFlags, _ characters: String = "f") throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 3))
        }
        #expect(BibleVersionKeyboardRouting.KeyView.isFindReadingShortcut(try event(.command)))
        #expect(BibleVersionKeyboardRouting.KeyView.isFindReadingShortcut(try event([.command, .capsLock], "F")))
        for flags: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            #expect(!BibleVersionKeyboardRouting.KeyView.isFindReadingShortcut(try event(flags)))
        }
        #expect(!BibleVersionKeyboardRouting.KeyView.isFindReadingShortcut(try event(.command, "g")))
    }
    @Test func newNoteCreatesAnEditableNoteAndRetainsTheActivePassageAndSelection() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Authored text for a note."]]); defer { fixture.remove() }
        let personal = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal)
        workspace.newNote()
        #expect(personal.documents.count == 1 && personal.documents[0].notes.count == 1)
        #expect(workspace.pendingNoteID == personal.documents[0].notes[0].id && workspace.activeTool == .documents)
        let reader = workspace.open(fixture.resources[0], startReading: false)
        let content = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        reader.page = .init(destination: .init(ordinal: 0), text: content.plainText, sectionCount: 1, content: content)
        reader.visibleBibleReference = "Ge 1:2"; reader.selectedRange = .init(location: 0, length: 8)
        workspace.newNote()
        let note = try #require(personal.documents[0].notes.last)
        #expect(personal.documents[0].notes.count == 2 && note.sourceContentType == "text/plain")
        #expect(note.sourceBody == "Authored" && note.effectiveAnchor.location?.reference == "Ge 1:2")
        #expect(workspace.pendingNoteID == note.id && personal.loadError == nil)
        workspace.closeAll()
    }
    @Test func resourceChooserSwitchesTheExistingDictionaryToTheChosenEdition() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First definition"], ["Second definition"]])
        defer { fixture.remove() }
        let workspace = workspace()
        workspace.resources = fixture.resources.map { source in
            var metadata = LibronMetadata(title: source.title, origin: "Authored test")
            metadata.resourceType = "Diccionario o enciclopedia"
            return LibraryResource(location: source.location, title: source.title, byteCount: source.byteCount,
                format: source.format, support: source.support, provenance: source.provenance, libron: metadata)
        }
        let first = workspace.resources[0], chosen = workspace.resources[1]
        StudyResourceKind.dictionary.open(first, in: workspace)
        let reader = try #require(workspace.activeReader)
        for _ in 0..<500 where reader.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        StudyResourceKind.dictionary.open(chosen, in: workspace)
        for _ in 0..<500 where reader.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.readers.count == 1 && workspace.activeReader === reader)
        #expect(reader.resource.id == chosen.id && reader.page?.text == "Second definition")
        #expect(workspace.dictionary.resourceID == chosen.id && reader.isDictionary)
        StudyResourceKind.bible.open(chosen, in: workspace)
        #expect(workspace.readers.count == 1 && workspace.activeReader === reader)
        workspace.closeAll()
    }
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
