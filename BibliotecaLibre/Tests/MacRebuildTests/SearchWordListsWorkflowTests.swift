import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct SearchWordListsWorkflowTests {
    @Test func actualSearchAndHistoryKeepWordFilters() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["faith hope"], ["faith hope fear"], ["faith alone"]]); defer { fixture.remove() }
        let personal = WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json"))
        let workspace = StudyWorkspace(personal: personal, resourceVisibility: .init(url: fixture.root.appendingPathComponent("hidden.json")))
        workspace.resources = fixture.resources
        workspace.search.query = "faith"; workspace.search.scope.kind = .library
        workspace.search.wordFilter = .init(include: ["hope"], exclude: ["fear"])
        workspace.search.run(workspace.availableResources, documents: personal.documents, scopeContext: workspace.searchScopeContext())
        for _ in 0..<1000 { if !workspace.search.isSearching { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(workspace.search.error == nil)
        #expect(workspace.search.report?.results.map(\.resourceID) == [fixture.resources[0].id])
        let saved = try #require(personal.searchHistory.entries.first?.configuration)
        let restored = WorkspaceSearchController(); try restored.restore(saved)
        #expect(restored.wordFilter == workspace.search.wordFilter)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "wordFilter")
        let old = try JSONDecoder().decode(WorkspaceSearchConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.wordFilter == nil)
        workspace.shutdown()
    }
}
