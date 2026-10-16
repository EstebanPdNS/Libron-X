import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct LibraryResourceVisibilityTests {
    private func resource(_ path: String, title: String = "Same title", format: ResourceFormat = .legacyLSF,
                          edition: String? = "edition-a") -> LibraryResource {
        .init(location: URL(fileURLWithPath: path), title: title, byteCount: 0, format: format,
              support: .metadataOnly, provenance: .fileName, legacyIdentifier: edition)
    }
    @Test func hiddenResourcesPersistAndRestoreWithoutTitleOrEditionCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hidden.json"), first = resource("/authored/one.lsf")
        let another = resource("/authored/two.lsf"), changedEdition = resource(first.id, edition: "edition-b")
        let changedFormat = resource(first.id, format: .libronixLLS)
        let store = LibraryResourceVisibility(url: url)
        try store.hide([first, first])
        #expect(store.hidden.count == 1 && store.isHidden(first))
        #expect(!store.isHidden(another) && !store.isHidden(changedEdition) && !store.isHidden(changedFormat))
        let reopened = LibraryResourceVisibility(url: url)
        #expect(reopened.hidden.count == 1 && reopened.isHidden(first))
        try reopened.restore([first.id])
        #expect(!LibraryResourceVisibility(url: url).isHidden(first))
    }
    @Test func hidingFiltersCatalogWithoutClosingReadersOrDiscardingArchiveResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StudyWorkspace(resourceVisibility: LibraryResourceVisibility(url: root.appendingPathComponent("hidden.json")))
        let first = resource("/authored/one.lsf"), second = resource("/authored/two.lsf")
        workspace.resources = [first, second]; workspace.librarySelection = first.id; workspace.search.resourceID = first.id
        let reader = workspace.open(first, startReading: false); reader.locator = "Gen 4.1"
        try workspace.hideLibraryResources([first.id])
        #expect(workspace.availableResources == [second] && workspace.filteredResources == [second])
        #expect(workspace.resources == [first, second] && workspace.archive().resources == [first, second])
        #expect(workspace.activeReader === reader && reader.locator == "Gen 4.1")
        #expect(workspace.librarySelection == nil && workspace.search.resourceID == nil)
        workspace.libraryQuery = "one"; #expect(workspace.filteredResources.isEmpty)
        try workspace.restoreLibraryResources([first.id])
        #expect(workspace.filteredResources == [first] && workspace.readers.count == 1)
        #expect(throws: (any Error).self) { try workspace.hideLibraryResources(["/missing"]) }
        #expect(workspace.resourceVisibility.hidden.isEmpty)
    }
    @Test func corruptAndFutureVisibilityFilesArePreservedAndCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for bytes in [Data("invalid".utf8), Data("{\"schemaVersion\":900,\"hidden\":[]}".utf8)] {
            let url = root.appendingPathComponent("hidden.json"); try bytes.write(to: url)
            let store = LibraryResourceVisibility(url: url)
            #expect(store.loadError != nil && store.hidden.isEmpty)
            #expect(throws: (any Error).self) { try store.hide([resource("/authored/one.lsf")]) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }
    @Test func concurrentChangesRejectTheMutationBeforeChangingTheVisibleCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hidden.json"), a = resource("/authored/a.lsf"), b = resource("/authored/b.lsf")
        let first = LibraryResourceVisibility(url: url), second = LibraryResourceVisibility(url: url)
        try first.hide([a])
        do { try second.hide([b]); Issue.record("Concurrent mutation was accepted") }
        catch PersonalStateError.concurrentChange {}
        #expect(second.hidden.isEmpty && !second.isHidden(b))
        #expect(LibraryResourceVisibility(url: url).isHidden(a))
        let external = LibraryResourceVisibility(url: url)
        try external.restore([a.id])
        do { try first.restore([a.id]); Issue.record("Concurrent restore was accepted") }
        catch PersonalStateError.concurrentChange {}
        #expect(first.isHidden(a) && LibraryResourceVisibility(url: url).hidden.isEmpty)
    }
    @Test func validationRejectsDuplicatePathsAndNoncanonicalResourceIdentities() throws {
        let good = HiddenLibraryResource(resource("/authored/a.lsf"))
        #expect(throws: (any Error).self) { try LibraryVisibilitySnapshot(hidden: [good, good]).validate() }
        var invalid = good; invalid.id = "relative.lsf"
        #expect(throws: (any Error).self) { try LibraryVisibilitySnapshot(hidden: [invalid]).validate() }
        invalid.id = "/authored/../other.lsf"
        #expect(throws: (any Error).self) { try LibraryVisibilitySnapshot(hidden: [invalid]).validate() }
    }
    @Test func hidingCancelsOldSearchAndNewSearchExaminesOnlyAvailableResources() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["needle original"], ["needle second"]])
        defer { fixture.remove() }
        let workspace = StudyWorkspace(resourceVisibility: LibraryResourceVisibility(url: fixture.root.appendingPathComponent("hidden.json")))
        workspace.resources = fixture.resources
        workspace.search.query = "needle"; workspace.search.allResources = true
        workspace.search.run(workspace.availableResources)
        try workspace.hideLibraryResources([fixture.resources[0].id])
        for _ in 0..<5 { await Task.yield() }
        #expect(!workspace.search.isSearching && workspace.search.report == nil)
        workspace.search.run(workspace.availableResources)
        for _ in 0..<1000 where workspace.search.isSearching { try await Task.sleep(for: .milliseconds(5)) }
        #expect(workspace.search.error == nil)
        let report = try #require(workspace.search.report)
        #expect(!report.results.isEmpty && report.results.allSatisfy { $0.resourceID == fixture.resources[1].id })
        #expect(report.resourceReports.count == 1)
    }
}
