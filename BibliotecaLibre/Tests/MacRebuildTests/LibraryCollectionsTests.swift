import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct LibraryCollectionsTests {
    @Test func manualMixedCollectionsRoundTripAndNeverChangeBooksOrBibleGroups() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Commentary"], ["Dictionary"], ["Author"]])
        defer { fixture.remove() }
        let resources = fixture.resources.enumerated().map { index, resource in
            LibraryResource(location: resource.location, title: resource.title, byteCount: resource.byteCount,
                format: [.legacyLSF, .eSwordSQLite, .epub][index], support: resource.support, provenance: resource.provenance)
        }
        let originals = try resources.map { try Data(contentsOf: $0.location) }
        let url = fixture.root.appendingPathComponent("collections.json"), store = LibraryCollections(url: url)
        let biblesURL = fixture.root.appendingPathComponent("parallel.json"), bibles = ParallelBibleSets(url: biblesURL)
        let bibleID = try bibles.create(); try bibles.add(resources[0], to: bibleID)
        let bibleBytes = try Data(contentsOf: biblesURL)
        let id = try store.create(); try store.rename(id, to: "  Autor — Ελληνικά 😀  ")
        try store.add(resources + [resources[0]], to: id)
        #expect(store.sets[0].name == "Autor — Ελληνικά 😀")
        #expect(store.sets[0].members.map(\.id) == resources.map(\.id))
        #expect(LibraryCollections(url: url).sets == store.sets)
        try store.removeMember(resources[1].id, from: id)
        #expect(LibraryCollections(url: url).sets[0].members.map(\.id) == [resources[0].id, resources[2].id])
        try store.remove(id)
        #expect(LibraryCollections(url: url).sets.isEmpty)
        #expect(try Data(contentsOf: biblesURL) == bibleBytes)
        #expect(try resources.map { try Data(contentsOf: $0.location) } == originals)
    }
    @Test func catalogFilterComposesWithTextFacetsAndVisibilityAndKeepsMissingMembers() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Alpha"], ["Beta"], ["Gamma"]]); defer { fixture.remove() }
        let store = LibraryCollections(url: fixture.root.appendingPathComponent("collections.json")), id = try store.create()
        try store.add([fixture.resources[0], fixture.resources[1]], to: id)
        let workspace = StudyWorkspace(personal: .init(url: fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility: .init(url: fixture.root.appendingPathComponent("visibility.json")),
            parallelBibleSets: .init(url: fixture.root.appendingPathComponent("bibles.json")), collections: store)
        workspace.resources = fixture.resources; workspace.libraryGroup = "collection:" + id.uuidString
        #expect(Set(workspace.filteredResources.map(\.id)) == Set(fixture.resources.prefix(2).map(\.id)))
        workspace.libraryQuery = fixture.resources[0].title
        #expect(workspace.filteredResources.map(\.id) == [fixture.resources[0].id])
        workspace.libraryQuery = ""; workspace.libraryFacetValue = "unmatched"
        #expect(workspace.filteredResources.isEmpty)
        workspace.libraryFacetValue = ""; try workspace.hideLibraryResources([fixture.resources[0].id])
        #expect(workspace.filteredResources.map(\.id) == [fixture.resources[1].id])
        workspace.resources = [fixture.resources[2]]
        #expect(workspace.filteredResources.isEmpty && store.sets[0].members.count == 2)
        workspace.resources = fixture.resources; try workspace.restoreLibraryResources([fixture.resources[0].id])
        #expect(workspace.filteredResources.count == 2)
        let member = store.sets[0].members[0]
        let changed = LibraryResource(location: fixture.resources[0].location, title: "Same path, different edition",
            byteCount: 1, format: .epub, support: .metadataOnly, provenance: .fileName, legacyIdentifier: "other")
        #expect(member.resolve(in: [changed]) == nil)
        workspace.libraryGroup = "collection:invalid"
        #expect(workspace.filteredResources.isEmpty)
        workspace.libraryGroup = "collection:" + UUID().uuidString
        #expect(workspace.filteredResources.isEmpty)
    }
    @Test func invalidEditsAndBulkOverflowAreAtomic() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Book"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("collections.json"), store = LibraryCollections(url: url)
        let id = try store.create(); try store.add(fixture.resources[0], to: id)
        let bytes = try Data(contentsOf: url), state = store.sets
        for name in [" \n ", String(repeating: "x", count: 161), "bad\0name"] {
            #expect(throws: (any Error).self) { try store.rename(id, to: name) }
        }
        let tooMany = (0..<8193).map { index in
            LibraryResource(location: fixture.root.appendingPathComponent("\(index).epub"), title: "\(index)",
                byteCount: 0, format: .epub, support: .metadataOnly, provenance: .fileName)
        }
        #expect(throws: (any Error).self) { try store.add(tooMany, to: id) }
        #expect(store.sets == state)
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test func malformedFutureDuplicateAndUnsafeMemberStateStayUntouched() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Book"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("collections.json"), member = LibraryCollectionMember(fixture.resources[0])
        var unsafe = member; unsafe.resourceID = "/tmp/../book"
        for bytes in [Data("broken json".utf8), try JSONEncoder().encode(LibraryCollectionsSnapshot(schemaVersion: 2)),
            try JSONEncoder().encode(LibraryCollectionsSnapshot(sets: [.init(name: "a", members: [member, member])])),
            try JSONEncoder().encode(LibraryCollectionsSnapshot(sets: [.init(name: "a", members: [unsafe])]))] {
            try bytes.write(to: url)
            let store = LibraryCollections(url: url)
            #expect(store.loadError != nil)
            #expect(throws: (any Error).self) { try store.create() }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }
    @Test func concurrentWriterMustReloadAndNewCollectionsHaveUniqueDefaultNames() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Book"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("collections.json")
        let first = LibraryCollections(url: url), second = LibraryCollections(url: url)
        let id = try first.create()
        do { _ = try second.create(); Issue.record("Stale writer replaced collections") }
        catch PersonalStateError.concurrentChange { }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(second.sets.isEmpty)
        try second.reload(); let other = try second.create()
        #expect(second.sets.map(\.id) == [id, other] && Set(second.sets.map(\.name)).count == 2)
        do { try first.rename(id, to: "Stale"); Issue.record("Stale writer renamed a collection") }
        catch PersonalStateError.concurrentChange { }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(LibraryCollections(url: url).sets == second.sets)
    }
}
