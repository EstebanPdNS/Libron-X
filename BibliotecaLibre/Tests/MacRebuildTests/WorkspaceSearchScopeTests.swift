import AppKit
import Foundation
import Testing
import CSQLite
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct WorkspaceSearchScopeTests {
    private func workspace(_ fixture: AuthoredReaderFixture) -> StudyWorkspace {
        .init(personal: .init(url: fixture.root.appendingPathComponent("personal.json")),
              resourceVisibility: .init(url: fixture.root.appendingPathComponent("visibility.json")),
              parallelBibleSets: .init(url: fixture.root.appendingPathComponent("bibles.json")),
              collections: .init(url: fixture.root.appendingPathComponent("collections.json")),
              resourcePriorities: .init(url: fixture.root.appendingPathComponent("priorities.json")))
    }
    private func settle(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Search scope did not settle")
    }
    private func changed(_ resource: LibraryResource) -> LibraryResource {
        .init(location: resource.location, title: resource.title, byteCount: resource.byteCount, format: .epub,
            support: .metadataOnly, provenance: .fileName, legacyIdentifier: "replacement", stableID: resource.id)
    }
    @Test func collectionUnionsDeduplicateIdentityPreserveNamesAndNeverCollapseEqualTitles() throws {
        let fixture = try AuthoredReaderFixture(documents: [["a"],["b"],["c"]]); defer { fixture.remove() }
        let resources = fixture.resources.map { LibraryResource(location: $0.location, title: "Same title", byteCount: $0.byteCount,
            format: $0.format, support: $0.support, provenance: $0.provenance) }
        let a = LibraryCollection(name: "A", members: resources.prefix(2).map(LibraryCollectionMember.init))
        let b = LibraryCollection(name: "B", members: resources.suffix(2).map(LibraryCollectionMember.init))
        let selection = WorkspaceSearchScopeSelection(); selection.kind = .collections; selection.collectionIDs = [a.id,b.id]
        let context = WorkspaceSearchScopeContext(library: resources, collections: [a,b])
        let snapshot = try WorkspaceSearchScopeResolver.resolve(selection, context: context)
        #expect(snapshot.complete && snapshot.requestedResourceCount == 3 && snapshot.resources.count == 3)
        #expect(Set(snapshot.resources.map(\.id)) == Set(resources.map(\.id)))
        #expect(Set(snapshot.names) == ["A","B"])
        selection.collectionIDs = [b.id,a.id]
        #expect(try WorkspaceSearchScopeResolver.resolve(selection, context: context).fingerprint == snapshot.fingerprint)
        var renamed = a; renamed.name = "Renamed"; renamed.members = []
        #expect(snapshot.resources.count == 3 && Set(snapshot.names) == ["A","B"])
        #expect(try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: resources, collections: [renamed,b])).fingerprint != snapshot.fingerprint)
    }
    @Test func unavailableHiddenAndReplacedMembersRemainExplicitAndDoNotWidenTheScope() throws {
        let fixture = try AuthoredReaderFixture(documents: [["a"],["b"],["c"],["d"]]); defer { fixture.remove() }
        let resources = fixture.resources, collection = LibraryCollection(name: "Requested", members: resources.map(LibraryCollectionMember.init))
        let context = WorkspaceSearchScopeContext(library: [resources[0],changed(resources[1]),resources[2]], collections: [collection], hidden: [.init(resources[2])])
        let selection = WorkspaceSearchScopeSelection(); selection.kind = .collections; selection.collectionIDs = [collection.id]
        let snapshot = try WorkspaceSearchScopeResolver.resolve(selection, context: context)
        #expect(snapshot.resources.map(\.id) == [resources[0].id] && !snapshot.complete && snapshot.requestedResourceCount == 4)
        #expect(Set(snapshot.issues.map(\.reason)) == [.changedIdentity,.hidden,.missing])
        selection.kind = .library
        let visible = try WorkspaceSearchScopeResolver.resolve(selection, context: context)
        #expect(visible.complete && visible.resources.count == 2)
        selection.kind = .collections; selection.collectionIDs.insert(UUID())
        #expect(try WorkspaceSearchScopeResolver.resolve(selection, context: context).issues.contains { $0.reason == .missingCollection })
    }
    @Test func subsetsRetainMissingIdentitiesUntilExplicitlyClearedOrReselected() throws {
        let fixture = try AuthoredReaderFixture(documents: [["a"],["b"]]); defer { fixture.remove() }
        let selection = WorkspaceSearchScopeSelection(); selection.kind = .subset
        let a = fixture.resources[0], unknown = fixture.root.appendingPathComponent("missing.LSF").path
        selection.selectSubset([a.id,unknown], in: fixture.resources)
        let snapshot = try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: fixture.resources))
        #expect(snapshot.requestedResourceCount == 2 && snapshot.resources.map(\.id) == [a.id] && snapshot.issues.first?.id == unknown)
        selection.selectSubset([a.id], in: [changed(a)])
        let replaced = try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: [changed(a)]))
        #expect(replaced.resources.isEmpty && replaced.issues.first?.reason == .changedIdentity)
        selection.clearSubset(); selection.selectSubset([a.id], in: [changed(a)])
        #expect(try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: [changed(a)])).complete)
        #expect(selection.selectedSubsetIDs == [a.id])
    }
    @Test func openScopeIncludesMinimizedReadersDeduplicatesDuplicatesAndRetainsItsSnapshot() throws {
        let fixture = try AuthoredReaderFixture(documents: [["a"],["b"],["c"]]); defer { fixture.remove() }
        let value = workspace(fixture); value.resources = Array(fixture.resources.prefix(2))
        value.open(fixture.resources[0], startReading: false)
        let minimized = value.open(fixture.resources[1], startReading: false); value.minimize(minimized)
        let external = value.open(fixture.resources[2], startReading: false)
        value.open(fixture.resources[0], startReading: false)
        let selection = WorkspaceSearchScopeSelection(); selection.kind = .openReaders
        let context = value.searchScopeContext(), snapshot = try WorkspaceSearchScopeResolver.resolve(selection, context: context)
        #expect(snapshot.complete && snapshot.resources.count == 3 && snapshot.externalResourceIDs == [external.resource.id])
        value.closeAll()
        #expect(snapshot.resources.count == 3)
        #expect(try WorkspaceSearchScopeResolver.resolve(selection, context: context).fingerprint == snapshot.fingerprint)
        #expect(try WorkspaceSearchScopeResolver.resolve(selection, context: value.searchScopeContext()).resources.isEmpty)
    }
    @Test func invalidPoolsAndUnavailableCollectionStorageFailWithoutAffectingOtherScopes() throws {
        let fixture = try AuthoredReaderFixture(documents: [["a"]]); defer { fixture.remove() }
        let resource = fixture.resources[0], selection = WorkspaceSearchScopeSelection(); selection.kind = .library
        #expect(throws: WorkspaceSearchScopeError.invalidIdentity) { try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: [resource,resource])) }
        #expect(try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: [resource], collectionsError: "broken")).complete)
        selection.kind = .collections; selection.collectionIDs = [UUID()]
        #expect(throws: PersonalStateError.self) { try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: [resource], collectionsError: "broken")) }
        selection.kind = .openReaders
        #expect(throws: WorkspaceSearchScopeError.invalidIdentity) { try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: [resource], openResources: [changed(resource)])) }
        selection.kind = .library
        #expect(try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: [resource], openResources: [changed(resource)])).complete)
        #expect(throws: PersonalStateError.self) { try WorkspaceSearchScopeResolver.resolve(selection, context: .init(library: [resource], visibilityError: "broken visibility")) }
    }
    @Test func textAndReferenceControllersKeepScopeOmissionsDistinctFromContentCoverage() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["needle John3:16"],["needle John3:17"],["other"]]); defer { fixture.remove() }
        let missing = LibraryResource(location: fixture.root.appendingPathComponent("missing.LSF"), title: "Missing", byteCount: 0, format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
        let collection = LibraryCollection(name: "Requested", members: [.init(fixture.resources[0]),.init(missing)])
        let context = WorkspaceSearchScopeContext(library: fixture.resources, collections: [collection])
        let text = WorkspaceSearchController(); text.scope.kind = .collections; text.scope.collectionIDs = [collection.id]; text.query = "needle"
        text.run(fixture.resources, scopeContext: context); try await settle { !text.isSearching }
        #expect(text.error == nil && text.report?.results.map(\.resourceID) == [fixture.resources[0].id])
        #expect(text.report?.coverageComplete == true && !text.coverageComplete && text.scopeSnapshot?.issues.count == 1)
        let refs = WorkspaceReferenceSearchController(); refs.scope.kind = .collections; refs.scope.collectionIDs = [collection.id]; refs.query = "John3"
        let doc = StudyDocument(title: "Personal John3:18", kind: .notebook)
        refs.run(resources: fixture.resources, documents: [doc], scopeContext: context); try await settle { !refs.isSearching }
        #expect(refs.error == nil && refs.report?.results.count == 2 && refs.report?.coverageComplete == true && !refs.coverageComplete)
        refs.includeLibrary = false
        refs.run(resources: [], documents: [doc], scopeContext: .init(library: [], visibilityError: "broken")); try await settle { !refs.isSearching }
        #expect(refs.coverageComplete && refs.scopeSnapshot == nil && refs.report?.results.count == 1)
    }
    @Test func externalReaderResultsOpenTheirBoundSourceAfterTheReaderClosesAndKeepArchiveValidity() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["catalog"],["😀 needle John3:16"]]); defer { fixture.remove() }
        let value = workspace(fixture); value.resources = [fixture.resources[0]]
        let external = value.open(fixture.resources[1], startReading: false)
        value.search.scope.kind = .openReaders; value.search.query = "needle"
        value.search.run(value.availableResources, scopeContext: value.searchScopeContext()); try await settle { !value.search.isSearching }
        let result = try #require(value.search.report?.results.first), scope = try #require(value.search.scopeSnapshot)
        value.close(external); value.activeTool = .search
        value.openSearchResult(result, scope: scope)
        let reader = try #require(value.activeReader); try await settle { !reader.isLoading }
        #expect(reader.resource.id == fixture.resources[1].id && reader.selectedText == "needle" && reader.error == nil)
        try value.archive().validate()
        try value.resourceVisibility.hide([reader.resource]); value.activeTool = .search
        value.openSearchResult(result, scope: scope)
        #expect(value.activeTool == .search && value.search.error != nil)
        value.closeAll()
    }
    @Test func emptyScopesAndSupersededQueriesNeverPublishACompleteEmptyLibraryResult() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["alpha"],["beta"]]); defer { fixture.remove() }
        let search = WorkspaceSearchController(); search.scope.kind = .openReaders; search.query = "alpha"
        search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.error != nil && search.report == nil && !search.coverageComplete)
        search.scope.kind = .subset; search.scope.selectSubset([fixture.resources[0].id], in: fixture.resources)
        search.run(fixture.resources)
        search.cancel(); search.scope.clearSubset(); search.scope.selectSubset([fixture.resources[1].id], in: fixture.resources)
        search.query = "beta"; search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.map(\.resourceID) == [fixture.resources[1].id])
        #expect(search.scopeSnapshot?.resources.map(\.id) == [fixture.resources[1].id])
    }
    @Test func resourceCollectionScopesComposeWithCustomBibleVerseRanges() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["catalog"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("owned.bbli")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned','O','Fixture'); CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'faith'),(1,1,2,'hope');", nil,nil,nil) == SQLITE_OK); sqlite3_close(db)
        let bible = try ESwordResource.inspect(url), collection = LibraryCollection(name: "Bible", members: [.init(bible)])
        let search = WorkspaceSearchController(); search.query = "faith"; search.bibleVerses = true
        search.bibleRangeMode = .custom; search.customBibleRange = "Ge1:2"; search.scope.kind = .collections; search.scope.collectionIDs = [collection.id]
        search.run(fixture.resources + [bible], scopeContext: .init(library: fixture.resources + [bible], collections: [collection])); try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.isEmpty == true)
        #expect(search.report?.counters.versesExamined == 1 && search.report?.counters.versesExcludedByRange == 1)
        #expect(search.scopeSnapshot?.resources.map(\.id) == [bible.id])
    }
}
