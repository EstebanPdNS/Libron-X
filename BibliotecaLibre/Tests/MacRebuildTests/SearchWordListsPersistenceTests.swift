import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct SearchWordListsPersistenceTests {
    @Test func listsPersistAndRejectConcurrentWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json"), first = WorkspacePersonalState(url: url), stale = WorkspacePersonalState(url: url)
        let list = SearchWordList(name: "Study", terms: ["faith", "hope"])
        try first.editSearchWordLists { $0.lists.append(list) }
        #expect(throws: (any Error).self) { try stale.editSearchWordLists { $0.lists.append(list) } }
        #expect(WorkspacePersonalState(url: url).searchWordLists.lists == [list])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func futureSchemaIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("search-word-lists.json"), bytes = Data(#"{"schemaVersion":99,"lists":[]}"#.utf8)
        try bytes.write(to: path)
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(state.searchWordListsLoadError != nil)
        #expect(throws: (any Error).self) { try state.editSearchWordLists { $0.lists = [] } }
        #expect(try Data(contentsOf: path) == bytes)
    }
}
