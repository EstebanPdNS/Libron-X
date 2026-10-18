import Foundation
import Testing
@testable import LibronixCore

@Suite(.serialized) struct LibrarySearchControlTests {
    actor Capture {
        var values: [LibrarySearchReport] = []
        var requestedPause = false
        func record(_ report: LibrarySearchReport) { values.append(report) }
        func shouldPause(_ report: LibrarySearchReport) -> Bool {
            guard !requestedPause, report.runState == .running, report.results.count == 1 else { return false }
            requestedPause = true; return true
        }
        var latest: LibrarySearchReport? { values.last }
    }
    private func awaitSuspension(_ control: LibrarySearchControl) async throws {
        for _ in 0..<2000 {
            if await control.suspendedWaiterCount == 1 { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Cooperative search never acknowledged its pause")
    }
    private func start(_ fixture: PersistentLibrarySearchTests.Fixture, source: PersistentLibrarySearchTests.Source,
                       control: LibrarySearchControl, capture: Capture, budget: LibrarySearchBudget = .init(progressBatchSize: 1)) throws -> Task<LibrarySearchReport, any Error> {
        let resource = fixture.resource, query = try SearchQueryParser.parse("needle")
        return Task {
            try await LibrarySearchService(provider: source).search(resources: [resource], query: query, budget: budget,
                control: control, onSnapshot: { report in
                    await capture.record(report)
                    if await capture.shouldPause(report) { await control.pause() }
                })
        }
    }
    @Test func PauseRetainsTheExactScanPositionAndDoesNotConsumeDurationBudget() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["needle first", "needle second"]); defer { fixture.remove() }
        let source = PersistentLibrarySearchTests.Source(), control = LibrarySearchControl(), capture = Capture()
        let began = ContinuousClock.now
        let task = try start(fixture, source: source, control: control, capture: capture, budget: .init(maximumDurationSeconds: 0.5, progressBatchSize: 1))
        try await awaitSuspension(control)
        #expect(await source.reads == 1)
        #expect(await capture.latest?.runState == .paused)
        try await Task.sleep(for: .milliseconds(700))
        #expect(await source.reads == 1)
        #expect(await control.suspendedWaiterCount == 1)
        await control.resume()
        let final = try await task.value
        #expect(final.coverageComplete && final.runState == .finished && final.results.count == 2)
        #expect(final.elapsedSeconds < 0.5 && began.duration(to: .now) >= .milliseconds(700))
        #expect(await source.reads == 2)
        #expect(await control.suspendedWaiterCount == 0)
        #expect(Set(final.results.map(\.id)).count == 2)
        let updates = await capture.values
        #expect(updates.contains { $0.runState == .paused && $0.results.count == 1 })
        #expect(updates.filter { $0.runState != .finished }.allSatisfy { !$0.coverageComplete })
        #expect(updates.last?.coverageComplete == true)
        for report in updates {
            #expect(report.counters.occurrencesReturned == report.results.reduce(0) { $0 + $1.hits.count + $1.externalHits.count })
        }
    }
    @Test(arguments: [false,true]) func BothCancellationPathsWakePausedSearchAndKeepPublishedResults(taskCancellation: Bool) async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["needle first", "needle second"]); defer { fixture.remove() }
        let source = PersistentLibrarySearchTests.Source(), control = LibrarySearchControl(), capture = Capture()
        let task = try start(fixture, source: source, control: control, capture: capture)
        try await awaitSuspension(control)
        if taskCancellation { task.cancel() } else { await control.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await control.suspendedWaiterCount == 0)
        #expect(await source.reads == 1)
        let last = try #require(await capture.latest)
        #expect(last.runState == .cancelled && !last.coverageComplete && last.results.count == 1)
    }
    @Test func ChangedSourceOnResumeInvalidatesTheRunBeforeReadingAnotherArticle() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["needle first", "needle second"]); defer { fixture.remove() }
        let source = PersistentLibrarySearchTests.Source(), control = LibrarySearchControl(), capture = Capture()
        let task = try start(fixture, source: source, control: control, capture: capture)
        try await awaitSuspension(control)
        try fixture.replace([.init(text: "changed needle first"), .init(text: "changed needle second")])
        await control.resume()
        await #expect(throws: LibrarySearchError.resumeSourceChanged) { try await task.value }
        let last = try #require(await capture.latest)
        #expect(last.runState == .failed && !last.coverageComplete && last.results.count == 1)
        #expect(await source.reads == 1)
    }
    @Test func PauseBeforeStartDoesNoSourceWorkAndCancelledGateCannotBeResumed() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["needle"]); defer { fixture.remove() }
        let source = PersistentLibrarySearchTests.Source(), control = LibrarySearchControl(), capture = Capture()
        await control.pause()
        let task = Task {
            try await LibrarySearchService(provider: source).search(resources: [fixture.resource], query: SearchQueryParser.parse("needle"),
                control: control, onSnapshot: { await capture.record($0) })
        }
        try await awaitSuspension(control)
        #expect(await source.reads == 0)
        #expect(await capture.latest?.results.isEmpty == true)
        await control.cancel(); await control.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await control.state == .cancelled)
        #expect(await control.suspendedWaiterCount == 0)
        await #expect(throws: CancellationError.self) { try await control.waitUntilRunning() }
    }
    @Test func LimitsStillFinishWithExplicitPartialCoverageAndNoDuplicateSnapshots() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["needle first", "needle second", "needle third"]); defer { fixture.remove() }
        let capture = Capture(), control = LibrarySearchControl()
        let report = try await LibrarySearchService(provider: PersistentLibrarySearchTests.Source()).search(resources: [fixture.resource], query: SearchQueryParser.parse("needle"),
            budget: .init(maximumArticles: 2, progressBatchSize: 1), control: control, onSnapshot: { await capture.record($0) })
        #expect(report.runState == .finished && !report.coverageComplete && report.limitReason == .articles && report.results.count == 2)
        let values = await capture.values
        var previous = Set<String>()
        for value in values {
            let ids = Set(value.results.map(\.id))
            #expect(ids.count == value.results.count && previous.isSubset(of: ids))
            previous = ids
        }
        #expect(values.last?.limitReason == .articles)
    }
}
