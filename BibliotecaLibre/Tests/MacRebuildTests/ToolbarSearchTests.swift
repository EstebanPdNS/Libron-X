import Foundation
import Testing
@testable import MacRebuild

@MainActor struct ToolbarSearchTests {
    private func workspace(_ fixture: AuthoredReaderFixture) -> StudyWorkspace {
        let value = StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility: LibraryResourceVisibility(url: fixture.root.appendingPathComponent("hidden.json")))
        value.resources = fixture.resources
        value.open(fixture.resources[0], startReading: false)
        return value
    }
    private func settle(_ value: StudyWorkspace) async throws {
        for _ in 0..<1000 { if !value.search.isSearching { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Toolbar search did not finish")
    }
    @Test func emptyToolbarSubmissionDoesNotReplaceAnOpenToolOrItsScope() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Gamma"]]); defer { fixture.remove() }
        let value = workspace(fixture)
        value.activeTool = .favorites; value.search.resourceID = "previous"; value.search.query = " \n "
        value.submitToolbarSearch()
        #expect(value.activeTool == .favorites && value.search.resourceID == "previous" && !value.search.isSearching)
    }
    @Test func toolbarSubmissionExecutesTheQueryAndPreservesResourceAndWholeLibraryScopes() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Gamma in first"], ["Gamma in second"]]); defer { fixture.remove() }
        let value = workspace(fixture); value.search.query = "Gamma"
        value.submitToolbarSearch(); try await settle(value)
        #expect(value.activeTool == .search && value.search.error == nil)
        #expect(value.search.report?.results.map(\.resourceID) == [fixture.resources[0].id])
        value.search.allResources = true; value.submitToolbarSearch(); try await settle(value)
        #expect(Set(value.search.report?.results.map(\.resourceID) ?? []) == Set(fixture.resources.map(\.id)))
        try value.hideLibraryResources([fixture.resources[1].id])
        value.submitToolbarSearch(); try await settle(value)
        #expect(value.search.report?.results.map(\.resourceID) == [fixture.resources[0].id])
        value.shutdown()
    }
}
