import Foundation
import Testing
@testable import MacRebuild

@MainActor struct WorkspaceSavedQueriesTests {
    @Test func namedQueryRoundTripsAndRestoresConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("saved-queries.json")
        let source = WorkspaceSearchController(); source.query = "faith OR hope"
        source.scope.kind = .collections; source.scope.collectionIDs = [UUID()]
        source.bibleVerses = true; source.bibleRangeMode = .custom; source.customBibleRange = "John 3"
        source.wholeWords = false; source.limits.results = 23
        let query = WorkspaceSavedQuery(title: "My study", configuration: source.historyConfiguration)
        let store = WorkspaceSavedQueries(url: url); try store.save(original: nil, replacement: query)
        let loaded = WorkspaceSavedQueries(url: url); let copy = try #require(loaded.queries.first)
        #expect(copy == query)
        let target = WorkspaceSearchController(); try target.restore(copy.configuration)
        #expect(target.historyConfiguration == source.historyConfiguration && target.phase == .idle)
        var changed = copy; changed.title = "Renamed"
        try loaded.save(original: copy, replacement: changed)
        #expect(throws: (any Error).self) { try loaded.remove(copy) }
        try loaded.remove(changed)
        #expect(WorkspaceSavedQueries(url: url).queries.isEmpty)
    }
    @Test func staleOrFutureStoreCannotOverwriteData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queries.json"), first = WorkspaceSavedQueries(url: url), stale = WorkspaceSavedQueries(url: url)
        let search = WorkspaceSearchController(); search.query = "faith"
        let query = WorkspaceSavedQuery(title: "Study", configuration: search.historyConfiguration)
        try first.save(original: nil, replacement: query)
        #expect(throws: (any Error).self) { try stale.save(original: nil, replacement: query) }
        let bytes = Data(#"{"schemaVersion":99,"queries":[]}"#.utf8); try bytes.write(to: url)
        let future = WorkspaceSavedQueries(url: url)
        #expect(future.loadError != nil)
        #expect(throws: (any Error).self) { try future.save(original: nil, replacement: query) }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
