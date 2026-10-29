import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

@MainActor struct ScriptureMemoryPersistenceTests {
    @Test func progressIsIndependentAndRejectsConcurrentWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("personal.json")
        let first = WorkspacePersonalState(url: path), stale = WorkspacePersonalState(url: path)
        let day = try ReadingDay(year: 2026, month: 10, day: 28)
        let card = ScriptureMemoryCard(reference: "Jn 1:1", passage: "In the beginning")
        try first.editScriptureMemory { $0.cards.append(card) }
        #expect(throws: (any Error).self) { try stale.editScriptureMemory { $0.cards.append(card) } }
        try first.editScriptureMemory { _ = try $0.cards[0].record(answer: "in the beginning", on: day) }
        let loaded = WorkspacePersonalState(url: path)
        #expect(loaded.scriptureMemory.cards.first?.correct == 1)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    @Test func futureSchemaIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("scripture-memory.json")
        let bytes = Data(#"{"schemaVersion":99,"cards":[]}"#.utf8); try bytes.write(to: file)
        let state = WorkspacePersonalState(url: root.appendingPathComponent("personal.json"))
        #expect(state.scriptureMemoryLoadError != nil)
        #expect(throws: (any Error).self) { try state.editScriptureMemory { $0.cards = [] } }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
