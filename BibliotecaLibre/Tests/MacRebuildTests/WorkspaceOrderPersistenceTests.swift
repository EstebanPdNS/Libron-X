import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct WorkspaceOrderPersistenceTests {
    private func workspace(_ fixture: AuthoredReaderFixture) -> StudyWorkspace {
        StudyWorkspace(personal: WorkspacePersonalState(url: fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility: LibraryResourceVisibility(url: fixture.root.appendingPathComponent("hidden.json")))
    }
    private func settle(_ workspace: StudyWorkspace) async throws {
        for _ in 0..<1000 {
            if workspace.readers.allSatisfy({ !$0.isLoading }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Restored readers did not settle")
    }
    @Test func repeatedDiskRecoveryPreservesTwelveDuplicatePanesOpeningAndStackingOrdersIndependently() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["One 😀"], ["Two 😀"], ["Three 😀"]]); defer { fixture.remove() }
        let source = workspace(fixture); source.resources = fixture.resources; source.libraryRoot = fixture.root
        let opened = (0..<12).map { source.open(fixture.resources[$0 % 3], destination: .init(ordinal: 0)) }
        try await settle(source)
        for (index, reader) in opened.enumerated() {
            reader.textScale = 1 + Double(index) / 20
            reader.frame = .init(x: Double(index) / 30, y: 0.1, width: 0.4, height: 0.7)
            reader.linkGroup = ReaderLinkGroup.allCases[1 + index % 6]
        }
        for index in [7, 2, 10, 3, 5] { source.activate(opened[index]) }
        source.minimize(opened[4]); source.referenceTargetID = opened[8].id
        let openingScales = opened.map(\.textScale), stackScales = source.readers.map(\.textScale)
        let original = source.archive(); try original.validate()
        #expect(original.openingOrder != Array(original.panes.indices))
        let path = fixture.root.appendingPathComponent("recovery.json")
        let firstStore = WorkspaceStartupStore(url: path); _ = try firstStore.load(); try firstStore.save(original)
        for _ in 0..<2 {
            let store = WorkspaceStartupStore(url: path), saved = try #require(try store.load())
            let recovered = workspace(fixture); try recovered.restore(saved); try await settle(recovered)
            #expect(recovered.orderedReaders.map(\.textScale) == openingScales)
            #expect(recovered.readers.map(\.textScale) == stackScales)
            #expect(recovered.activeReader?.textScale == opened[5].textScale)
            #expect(recovered.readers.first { $0.id == recovered.referenceTargetID }?.textScale == opened[8].textScale)
            #expect(recovered.orderedReaders[4].isMinimized)
            #expect(recovered.archive().panes.map(\.frame) == original.panes.map(\.frame))
            #expect(recovered.archive().panes.map(\.link) == original.panes.map(\.link))
            #expect(recovered.readers.allSatisfy { $0.page != nil && $0.error == nil })
            recovered.cycleReader(); #expect(recovered.activeReader?.textScale == opened[6].textScale)
            recovered.cycleReader(backwards: true); #expect(recovered.activeReader?.textScale == opened[5].textScale)
            // Save before cycling again so a second fresh disk decode is
            // checked against the original stack, rather than a shared object.
            let preserved = workspace(fixture); try preserved.restore(saved); try await settle(preserved)
            try store.save(preserved.archive())
            recovered.shutdown(); preserved.shutdown()
        }
        source.shutdown()
    }
    @Test func olderSchemaOneJSONWithoutOpeningOrderRetainsItsStoredPaneOrder() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["First"], ["Second"]]); defer { fixture.remove() }
        let source = workspace(fixture)
        let first = source.open(fixture.resources[0], startReading: false)
        source.open(fixture.resources[1], startReading: false); source.activate(first)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source.archive())) as? [String: Any])
        object.removeValue(forKey: "openingOrder")
        let legacy = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.openingOrder == nil); try legacy.validate()
        let recovered = workspace(fixture); try recovered.restore(legacy)
        #expect(recovered.orderedReaders.map(\.resource) == legacy.panes.map(\.resource))
        #expect(recovered.activeReader?.resource == first.resource)
        #expect(recovered.archive().openingOrder == [0, 1])
    }
    @Test func invalidOpeningPermutationsCannotReplaceLiveReadersOrOverwriteARecoveryFile() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First"]]); defer { fixture.remove() }
        let workspace = workspace(fixture)
        let first = workspace.open(fixture.resources[0], startReading: false)
        workspace.open(fixture.resources[0], startReading: false)
        workspace.referenceTargetID = first.id
        let originalIDs = workspace.readers.map(\.id), order = workspace.readerOrder, active = workspace.activeID
        let path = fixture.root.appendingPathComponent("recovery.json")
        let store = WorkspaceStartupStore(url: path); _ = try store.load(); try store.save(workspace.archive())
        let originalBytes = try Data(contentsOf: path)
        for invalid in [[], [0], [0, 0], [-1, 1], [0, 2], [0, 1, 2]] {
            var damaged = workspace.archive(); damaged.openingOrder = invalid
            #expect(throws: PersonalStateError.self) { try workspace.restore(damaged) }
            #expect(throws: PersonalStateError.self) { try store.save(damaged) }
            #expect(workspace.readers.map(\.id) == originalIDs && workspace.readerOrder == order && workspace.activeID == active)
            #expect(workspace.referenceTargetID == first.id)
            #expect(try Data(contentsOf: path) == originalBytes)
        }
    }
    @Test func allMinimizedAndEmptyLayoutsKeepTheirOrderWithoutInventingAnActivePane() throws {
        let fixture = try AuthoredReaderFixture(documents: [["First"]]); defer { fixture.remove() }
        let source = workspace(fixture)
        let first = source.open(fixture.resources[0], startReading: false)
        let second = source.open(fixture.resources[0], startReading: false)
        first.textScale = 1.25; second.textScale = 1.5
        source.activate(first); source.referenceTargetID = second.id
        source.minimize(first); source.minimize(second)
        let recovered = workspace(fixture); try recovered.restore(source.archive())
        #expect(recovered.activeReader == nil && recovered.visibleReaders.isEmpty)
        #expect(recovered.orderedReaders.map(\.textScale) == [1.25, 1.5])
        #expect(recovered.readers.first { $0.id == recovered.referenceTargetID }?.textScale == 1.5)
        recovered.closeAll(); let empty = recovered.archive(); try empty.validate()
        #expect(empty.openingOrder == []); try recovered.restore(empty)
        #expect(recovered.readers.isEmpty && recovered.activeID == nil && recovered.referenceTargetID == nil && recovered.readerOrder.isEmpty)
    }
}
