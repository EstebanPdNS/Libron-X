import Foundation
import Testing
@testable import MacRebuild

@MainActor struct WorkspaceSearchHistoryTests {
    @Test func configurationRestoresAllOptionsAndPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("search-history.json")
        let search = WorkspaceSearchController()
        search.query = "faith AND hope"; search.searchField = .body
        search.approximatePhrase = true; search.maximumEdits = 3
        search.scope.kind = .subset; search.resourceID = "/resource"
        search.scope.collectionIDs = [UUID()]
        search.scope.restoreSubset(members: [], unresolvedIDs: ["/missing"])
        search.caseSensitive = true; search.wholeWords = false; search.bibleVerses = true
        search.bibleRangeMode = .savedList; search.customBibleRange = "John 3"; search.referenceListID = UUID()
        search.limits = .init(durationSeconds: 33, articles: 1234, results: 88, occurrences: 999)
        let expected = search.historyConfiguration
        let history = WorkspaceSearchHistory(url: url)
        try history.record(expected); try history.record(expected)
        #expect(history.entries.count == 1)
        let reloaded = WorkspaceSearchHistory(url: url)
        let saved = try #require(reloaded.entries.first)
        let restored = WorkspaceSearchController()
        try restored.restore(saved.configuration)
        #expect(restored.historyConfiguration == expected)
        #expect(restored.phase == .idle && restored.report == nil)
        try reloaded.remove(saved.id)
        #expect(WorkspaceSearchHistory(url: url).entries.isEmpty)
    }
    @Test func concurrentAndFutureFilesAreNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), first = WorkspaceSearchHistory(url: url), stale = WorkspaceSearchHistory(url: url)
        let search = WorkspaceSearchController(); search.query = "faith"
        try first.record(search.historyConfiguration)
        #expect(throws: (any Error).self) { try stale.record(search.historyConfiguration) }
        let future = Data(#"{"schemaVersion":99,"entries":[]}"#.utf8)
        try future.write(to: url)
        let unreadable = WorkspaceSearchHistory(url: url)
        #expect(unreadable.loadError != nil)
        #expect(throws: (any Error).self) { try unreadable.record(search.historyConfiguration) }
        #expect(try Data(contentsOf: url) == future)
    }
}
