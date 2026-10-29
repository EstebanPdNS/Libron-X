import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite @MainActor struct NamedBibleSearchRangesTests {
    @Test func savedRangesValidatePersistAndProtectConcurrentChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("personal.json")
        let first = WorkspacePersonalState(url: url), stale = WorkspacePersonalState(url: url)
        let range = NamedBibleSearchRange(name: "Selected", expression: "John3:16–18; Romans8")
        try first.editNamedBibleRanges { $0.ranges.append(range) }
        #expect(WorkspacePersonalState(url: url).namedBibleRanges.ranges == [range])
        #expect(throws: (any Error).self) { try stale.editNamedBibleRanges { $0.ranges.append(range) } }
        #expect(throws: (any Error).self) { try first.editNamedBibleRanges { $0.ranges.append(.init(name: "Bad", expression: "invalid reference")) } }
        #expect(first.namedBibleRanges.ranges == [range])
        try first.editNamedBibleRanges { $0.ranges.removeAll() }
        #expect(WorkspacePersonalState(url: url).namedBibleRanges.ranges.isEmpty)
    }
    @Test func olderSearchConfigurationsDecodeWithoutNamedRangeFields() throws {
        let search = WorkspaceSearchController()
        search.query = "faith"; search.excludedRange = .init(mode: .custom, customRange: "John3")
        let data = try JSONEncoder().encode(search.historyConfiguration)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "namedRangeID")
        var exclusion = try #require(object["excludedRange"] as? [String: Any])
        exclusion.removeValue(forKey: "namedRangeID"); object["excludedRange"] = exclusion
        let decoded = try JSONDecoder().decode(WorkspaceSearchConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.namedRangeID == nil && decoded.excludedRange?.namedRangeID == nil)
        #expect(decoded.excludedRange?.customRange == "John3")
    }
    @Test func futureSchemaCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("named-bible-ranges.json")
        let original = Data(#"{"schemaVersion":99,"ranges":[]}"#.utf8)
        try original.write(to: path)
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(state.namedBibleRangesLoadError != nil)
        #expect(throws: (any Error).self) { try state.editNamedBibleRanges { $0.ranges.append(.init(name: "X", expression: "John3")) } }
        #expect(try Data(contentsOf: path) == original)
    }
}
