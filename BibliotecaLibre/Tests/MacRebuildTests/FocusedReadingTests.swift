import Foundation
import Testing
@testable import MacRebuild

@MainActor struct FocusedReadingTests {
    @Test func focusLeavesWorkspaceAndReaderStateIntact() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First"], ["Second"]]); defer { fixture.remove() }
        let workspace = StudyWorkspace(personal: .init(url: fixture.root.appendingPathComponent("personal.json")),
                                       resourceVisibility: .init(url: fixture.root.appendingPathComponent("hidden.json")))
        let first = workspace.open(fixture.resources[0], startReading: false)
        let second = workspace.open(fixture.resources[1], startReading: false)
        first.showsContents = true; second.showsLocator = true
        let firstFrame = first.frame, secondFrame = second.frame
        workspace.enterFocusedReading()
        #expect(workspace.focusedReader === second)
        #expect(workspace.readers.count == 2 && first.frame == firstFrame && second.frame == secondFrame)
        #expect(first.showsContents && second.showsLocator)
        workspace.exitFocusedReading()
        #expect(workspace.focusedReader == nil && workspace.activeReader === second)
        #expect(first.frame == firstFrame && second.frame == secondFrame)
        workspace.enterFocusedReading(); workspace.activate(first)
        #expect(workspace.focusedReader == nil && workspace.activeReader === first)
        workspace.enterFocusedReading(); workspace.minimize(first)
        #expect(workspace.focusedReader == nil)
        workspace.enterFocusedReading(); workspace.close(second)
        #expect(workspace.focusedReader == nil)
    }
}
