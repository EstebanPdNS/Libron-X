import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct WorkspaceLongSearchTests {
    actor SlowSource: LibrarySearchContentProvider {
        let base = WorkspaceSearchReader()
        var reads: [String: Int] = [:]
        var prepares = 0
        func supports(_ resource: LibraryResource) async -> Bool { await base.supports(resource) }
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            prepares += 1; return try await base.prepare(resource)
        }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
            reads[resource.id, default: 0] += 1
            try await Task.sleep(for: .milliseconds(8))
            return try await base.read(resource, article: article, prepared: prepared)
        }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws { try await base.verifyUnchanged(resource, prepared: prepared) }
        func count(_ id: String) -> Int { reads[id, default: 0] }
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<5000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        Issue.record("Controlled search did not settle")
    }
    private func pauseAfterProgress(_ search: WorkspaceSearchController) async throws {
        try await settle { search.phase == .running && (search.report?.results.count ?? 0) >= 16 }
        search.pause(); try await settle { search.phase == .paused }
    }
    @Test func ProgressiveResultsKeepSelectionAcrossPauseAndExactContinuation() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [(0..<40).map { "needle article \($0)" }]); defer { fixture.remove() }
        let source = SlowSource(), search = WorkspaceSearchController(providerFactory: { source })
        search.resourceID = fixture.resources[0].id; search.query = "needle"; search.run(fixture.resources)
        try await settle { search.phase == .running && (search.report?.results.count ?? 0) >= 16 }
        #expect(!search.coverageComplete && search.canOpenResults)
        search.presentation.next(); let selected = search.presentation.selectedID
        search.pause(); try await settle { search.phase == .paused }
        let reads = await source.count(fixture.resources[0].id), count = search.report?.results.count
        #expect(search.isSearching && (count ?? 0) >= 16 && (count ?? 40) < 40)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await source.count(fixture.resources[0].id) == reads)
        #expect(search.report?.results.count == count && search.report?.runState == .paused)
        search.query = "different request"; search.resume()
        #expect(search.phase == .paused && search.error != nil && !search.canOpenResults)
        search.query = "needle"; search.resume(); try await settle { !search.isSearching }
        #expect(search.error == nil)
        #expect(search.phase == .finished && search.coverageComplete && search.report?.results.count == 40)
        #expect(search.presentation.selectedID == selected && search.presentation.rows.count == 40)
        #expect(await source.count(fixture.resources[0].id) == 40)
        #expect(Set(search.report!.results.map(\.id)).count == 40)
    }
    @Test func CancellingPausedSearchRetainsPublishedPartialResultsButCannotResume() async throws {
        let fixture = try AuthoredReaderFixture(documents: [(0..<40).map { "needle \($0)" }]); defer { fixture.remove() }
        let source = SlowSource(), search = WorkspaceSearchController(providerFactory: { source })
        search.resourceID = fixture.resources[0].id; search.query = "needle"; search.run(fixture.resources)
        try await pauseAfterProgress(search)
        let count = search.report?.results.count, reads = await source.count(fixture.resources[0].id)
        search.cancel(); try await settle { !search.isSearching }
        #expect(search.phase == .cancelled && search.report?.runState == .cancelled && !search.coverageComplete)
        #expect(search.report?.results.count == count && search.canOpenResults)
        search.resume(); try await Task.sleep(for: .milliseconds(20))
        #expect(search.phase == .cancelled)
        #expect(await source.count(fixture.resources[0].id) == reads)
        search.clear(); #expect(search.phase == .idle && search.report == nil && search.presentation.rows.isEmpty)
    }
    @Test func ChangedPausedSourceDisablesOpeningAndRequiresANewSearch() async throws {
        let fixture = try AuthoredReaderFixture(documents: [(0..<40).map { "needle \($0)" }]); defer { fixture.remove() }
        let source = SlowSource(), search = WorkspaceSearchController(providerFactory: { source })
        search.resourceID = fixture.resources[0].id; search.query = "needle"; search.run(fixture.resources)
        try await pauseAfterProgress(search)
        let reads = await source.count(fixture.resources[0].id)
        var bytes = try Data(contentsOf: fixture.resources[0].location); bytes.append(0); try bytes.write(to: fixture.resources[0].location)
        search.resume(); try await settle { !search.isSearching }
        #expect(search.phase == .failed && search.error != nil && search.report?.runState == .failed && !search.canOpenResults)
        #expect(await source.count(fixture.resources[0].id) == reads)
    }
    @Test func LimitsAreValidatedBeforeWorkAndLargerLimitsRequireANewExplicitRun() async throws {
        let fixture = try AuthoredReaderFixture(documents: [(0..<5).map { "needle \($0)" }]); defer { fixture.remove() }
        let source = SlowSource(), search = WorkspaceSearchController(providerFactory: { source })
        search.resourceID = fixture.resources[0].id; search.query = "needle"; search.limits.articles = 2; search.run(fixture.resources)
        try await settle { !search.isSearching }
        #expect(search.phase == .finished && search.report?.limitReason == .articles && search.report?.results.count == 2 && !search.coverageComplete)
        search.limits.articles = 5
        #expect(search.configurationChanged && !search.canOpenResults && search.report?.results.count == 2)
        search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.count == 5 && search.canOpenResults)
        let prepares = await source.prepares
        search.limits.results = 0; search.run(fixture.resources)
        #expect(search.phase == .failed && !search.isSearching && search.report == nil && search.error != nil)
        #expect(await source.prepares == prepares)
    }
    @Test func ChangedConfigurationKeepsTheSubmittedQueryLabelAndBlocksAccidentalOpening() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["needle"]]); defer { fixture.remove() }
        let search = WorkspaceSearchController(); search.resourceID = fixture.resources[0].id; search.query = "needle"
        search.run(fixture.resources); try await settle { !search.isSearching }
        #expect(search.canOpenResults && search.submittedQuery == "needle")
        search.query = "other"; #expect(search.configurationChanged && !search.canOpenResults && search.submittedQuery == "needle")
        search.query = "needle"; #expect(!search.configurationChanged && search.canOpenResults)
        search.maximumEdits = 3; #expect(!search.configurationChanged) // Unused exact-mode control.
        search.approximatePhrase = true; #expect(search.configurationChanged && !search.canOpenResults)
    }
    @Test func ReplacingAPausedQueryCannotPublishItsLateCancelledSnapshotIntoTheNewRun() async throws {
        let fixture = try AuthoredReaderFixture(documents: [(0..<40).map { "oldNeedle \($0)" }, (0..<40).map { "newNeedle \($0)" }]); defer { fixture.remove() }
        let source = SlowSource(), search = WorkspaceSearchController(providerFactory: { source })
        search.resourceID = fixture.resources[0].id; search.query = "oldNeedle"; search.run(fixture.resources)
        try await pauseAfterProgress(search)
        let oldReads = await source.count(fixture.resources[0].id)
        search.resourceID = fixture.resources[1].id; search.query = "newNeedle"; search.run(fixture.resources)
        try await settle { !search.isSearching }
        try await Task.sleep(for: .milliseconds(30))
        #expect(search.phase == .finished && search.coverageComplete && search.submittedQuery == "newNeedle")
        #expect(search.report?.results.count == 40 && search.report?.results.allSatisfy { $0.resourceID == fixture.resources[1].id } == true)
        #expect(await source.count(fixture.resources[0].id) == oldReads)
        #expect(await source.count(fixture.resources[1].id) == 40)
    }
}
