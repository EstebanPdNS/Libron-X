import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ParallelBibleSetsTests {
    private func groupStore(_ fixture: AuthoredReaderFixture) -> ParallelBibleSets {
        .init(url: fixture.root.appendingPathComponent("parallel.json"))
    }
    private func samplePage(_ fixture: AuthoredReaderFixture) throws -> ReaderPage {
        let base = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        let anchor = LegacyReferenceAnchor(reference: "bible.1.3.5", flags: 0, dataTypeCode: 16,
            characterOffset: 0, decodedOffset: 0, referenceFormatFlags: 0)
        let content = LegacySectionContent(descriptor: base.descriptor, plainText: base.plainText, runs: base.runs,
            expectedCharacterCount: base.expectedCharacterCount, recognizedFormat: base.recognizedFormat,
            paragraphs: base.paragraphs, anchors: [anchor], markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        return .init(destination: .init(ordinal: 0, reference: "Ge 3:5"), text: base.plainText, sectionCount: 1,
                     selection: .init(location: 0, length: 0), content: content)
    }
    private func workspace(_ fixture: AuthoredReaderFixture, sets: ParallelBibleSets) -> StudyWorkspace {
        let value = StudyWorkspace(personal: .init(url: fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility: .init(url: fixture.root.appendingPathComponent("visibility.json")), parallelBibleSets: sets)
        value.resources = fixture.resources; return value
    }
    private func waitFor(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }; try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Parallel set operation did not settle")
    }
    @Test func orderedCRUDRoundTripNeverTouchesResourceBytes() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"], ["Two"], ["Three"]]); defer { fixture.remove() }
        let originals = try fixture.resources.map { try Data(contentsOf: $0.location) }
        let sets = groupStore(fixture), id = try sets.create()
        try sets.rename(id, to: "  Comparación — Ελληνικά  ")
        for resource in fixture.resources { try sets.add(resource, to: id) }
        try sets.add(fixture.resources[0], to: id) // No duplicates.
        try sets.moveMember(fixture.resources[2].id, in: id, by: -1)
        #expect(sets.sets[0].members.map(\.id) == [fixture.resources[0].id,fixture.resources[2].id,fixture.resources[1].id])
        #expect(groupStore(fixture).sets == sets.sets && sets.sets[0].name == "Comparación — Ελληνικά")
        let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("parallel.json"))
        #expect(throws: (any Error).self) { try sets.rename(id, to: " \n ") }
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("parallel.json")) == bytes)
        try sets.removeMember(fixture.resources[2].id, from: id)
        #expect(sets.sets[0].members.count == 2)
        try sets.remove(id)
        #expect(groupStore(fixture).sets.isEmpty)
        #expect(try fixture.resources.map { try Data(contentsOf: $0.location) } == originals)
    }
    @Test func malformedFutureOrDuplicateStateCannotBeOverwritten() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("parallel.json")
        let member = ParallelBibleMember(fixture.resources[0])
        let bad = [Data("bad json".utf8), try JSONEncoder().encode(ParallelBibleSetsSnapshot(schemaVersion: 2)),
            try JSONEncoder().encode(ParallelBibleSetsSnapshot(sets: [.init(name: "Empty", members: [member, member])])),
            try JSONEncoder().encode(ParallelBibleSetsSnapshot(sets: [.init(name: " ")])),
            try JSONEncoder().encode(ParallelBibleSetsSnapshot(sets: [.init(name: String(repeating: "a", count: 161))]))]
        for bytes in bad {
            try bytes.write(to: url)
            let sets = groupStore(fixture)
            #expect(sets.loadError != nil)
            #expect(throws: (any Error).self) { try sets.create() }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }
    @Test func conflictsRequireExplicitReloadAndPreserveBothIntents() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"]]); defer { fixture.remove() }
        let first = groupStore(fixture), second = groupStore(fixture)
        let id = try first.create()
        do { _ = try second.create(); Issue.record("A stale writer replaced another instance's group") }
        catch PersonalStateError.concurrentChange { }
        catch { Issue.record("Unexpected conflict error: \(error)") }
        #expect(second.sets.isEmpty && groupStore(fixture).sets.map(\.id) == [id])
        try second.reload(); let another = try second.create()
        #expect(groupStore(fixture).sets.map(\.id) == [id, another])
    }
    @Test func missingAndDifferentEditionsStayDistinct() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"], ["Two"]]); defer { fixture.remove() }
        let member = ParallelBibleMember(fixture.resources[0])
        #expect(member.resolve(in: [fixture.resources[1]]) == nil)
        let otherEdition = LibraryResource(location: fixture.resources[0].location, title: fixture.resources[0].title,
            byteCount: 1, format: .libronixLLS, support: .metadataOnly, provenance: .fileName, legacyIdentifier: "other")
        #expect(member.resolve(in: [otherEdition]) == nil)
        let sets = groupStore(fixture), id = try sets.create()
        try sets.add(fixture.resources[0], to: id)
        #expect(groupStore(fixture).sets[0].members == [member])
    }
    @Test func arrowsUseSavedOrderAndExcludeHiddenMembers() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"], ["Two"], ["Three"]]); defer { fixture.remove() }
        let sets = groupStore(fixture), id = try sets.create()
        for index in [0,2,1] { try sets.add(fixture.resources[index], to: id) }
        let workspace = workspace(fixture, sets: sets), page = try samplePage(fixture)
        let reader = ReaderSession(resource: fixture.resources[0], loader: { _, destination in
            #expect(destination.reference == "Ge 3:5"); return page
        })
        reader.page = page; reader.parallelSetID = id; reader.linkGroup = .c
        workspace.readers = [reader]; workspace.readerOrder = [reader.id]; workspace.activeID = reader.id; workspace.connect(reader)
        workspace.referenceTargetID = reader.id
        workspace.cycleBibleVersion(reader)
        try await waitFor { reader.resource.id == fixture.resources[2].id && !reader.isLoading }
        #expect(reader.parallelSetID == id && reader.linkGroup == .c && workspace.referenceTargetID == reader.id)
        workspace.cycleBibleVersion(reader, backwards: true)
        try await waitFor { reader.resource.id == fixture.resources[0].id && !reader.isLoading }
        try workspace.hideLibraryResources([fixture.resources[2].id])
        workspace.cycleBibleVersion(reader)
        try await waitFor { reader.resource.id == fixture.resources[1].id && !reader.isLoading }
        #expect(reader.currentReference == "Ge 3:5" && sets.sets[0].members.count == 3)
        workspace.shutdown()
    }
    @Test func deletedSetDoesNotFallBackToUnrelatedBibles() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"], ["Two"]]); defer { fixture.remove() }
        let sets = groupStore(fixture), id = try sets.create(), workspace = workspace(fixture, sets: sets)
        let reader = workspace.open(fixture.resources[0], startReading: false)
        reader.page = try samplePage(fixture); reader.parallelSetID = id
        try sets.remove(id); workspace.cycleBibleVersion(reader)
        #expect(reader.resource.id == fixture.resources[0].id && reader.error != nil && !reader.isLoading)
        workspace.shutdown()
    }
    @Test func savedGroupCyclesRealLegacyAndLibronixEditions() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_BIBLE_VERSION_CORPUS"] else { return }
        let fixture = try AuthoredReaderFixture(documents: [["Owned state only"]]); defer { fixture.remove() }
        let imported = try await LibraryImporter().importDirectory(at: URL(fileURLWithPath: path)) { _ in }
        let resources = try ["RVR60.LSF", "NVI.lbxlls", "RVR95.LSF"].map { name in
            try #require(imported.resources.first { $0.fileName == name })
        }
        let sets = groupStore(fixture), id = try sets.create(), workspace = workspace(fixture, sets: sets)
        workspace.resources = resources
        for resource in resources { try sets.add(resource, to: id) }
        let reader = workspace.open(resources[0], destination: .init(ordinal: 0, reference: "Ge 3:6"))
        defer { workspace.shutdown() }
        try await waitFor { !reader.isLoading }
        workspace.selectParallelBibleGroup(id, for: reader)
        workspace.cycleBibleVersion(reader)
        try await waitFor { !reader.isLoading && reader.resource.id == resources[1].id }
        #expect(reader.currentReference == "Ge 3:6" && reader.parallelSetID == id)
        workspace.cycleBibleVersion(reader, backwards: true)
        try await waitFor { !reader.isLoading && reader.resource.id == resources[0].id }
        #expect(reader.currentReference == "Ge 3:6" && reader.error == nil)
        print("Saved parallel group: actual LSF -> LLS -> LSF, exact Ge 3:6")
    }
    @Test func groupSelectionActivatesOnlyOwnedCompatibleReaders() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"], ["Two"]]); defer { fixture.remove() }
        let sets = groupStore(fixture), id = try sets.create(), workspace = workspace(fixture, sets: sets)
        try sets.add(fixture.resources[0], to: id)
        let first = workspace.open(fixture.resources[0], startReading: false)
        let second = workspace.open(fixture.resources[1], startReading: false)
        workspace.selectParallelBibleGroup(id, for: first)
        #expect(first.parallelSetID == id && workspace.activeID == first.id)
        workspace.selectParallelBibleGroup(id, for: second)
        #expect(second.parallelSetID == nil && workspace.activeID == first.id)
        workspace.close(first); workspace.selectParallelBibleGroup(nil, for: first)
        #expect(first.parallelSetID == id && workspace.activeID == second.id)
        workspace.shutdown()
    }
    @Test func workspaceAndDuplicateKeepSetSelectionAndOldArchivesStillDecode() throws {
        let fixture = try AuthoredReaderFixture(documents: [["One"]]); defer { fixture.remove() }
        let sets = groupStore(fixture), workspace = workspace(fixture, sets: sets), id = try sets.create()
        let reader = workspace.open(fixture.resources[0], startReading: false); reader.parallelSetID = id
        let duplicate = workspace.duplicate(reader)
        #expect(duplicate.parallelSetID == id)
        let bytes = try JSONEncoder().encode(workspace.archive())
        let saved = try JSONDecoder().decode(WorkspaceArchive.self, from: bytes)
        try saved.validate(); try workspace.restore(saved)
        #expect(workspace.readers.allSatisfy { $0.parallelSetID == id })
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var panes = try #require(object["panes"] as? [[String: Any]])
        for i in panes.indices { panes[i].removeValue(forKey: "parallelSetID") }; object["panes"] = panes
        let legacy = try JSONDecoder().decode(WorkspaceArchive.self, from: JSONSerialization.data(withJSONObject: object))
        try legacy.validate(); #expect(legacy.panes.allSatisfy { $0.parallelSetID == nil })
        workspace.shutdown()
    }
}
