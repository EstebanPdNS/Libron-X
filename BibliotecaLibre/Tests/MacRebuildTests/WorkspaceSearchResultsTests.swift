import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct WorkspaceSearchResultsTests {
    private func settle(_ reader: ReaderSession) async throws {
        for _ in 0..<2000 { if !reader.isLoading { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Search occurrence opening did not settle")
    }
    @Test func GroupOrderAndLayoutPreserveEveryOccurrenceIdentityAndOriginalReport() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["needle needle needle", "needle"], ["needle needle"]]); defer { fixture.remove() }
        let resources = fixture.resources.enumerated().map { index, source in
            LibraryResource(location: source.location, title: index == 0 ? "Zeta" : "Alpha", byteCount: source.byteCount, format: source.format, support: source.support, provenance: source.provenance)
        }
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: resources, query: SearchQueryParser.parse("needle"))
        let original = report.results, controller = WorkspaceSearchResultsController(); controller.setResults(original)
        #expect(controller.rows.count == 6 && controller.sections.map(\.title) == ["Zeta", "Alpha"])
        let identities = Set(controller.rows.map(\.id))
        controller.next(); let selected = controller.selectedID
        controller.order = .titleAscending
        #expect(controller.sections.map(\.title) == ["Alpha", "Zeta"] && controller.selectedID == selected)
        controller.layout = .aligned; controller.grouping = .none
        #expect(controller.sections.count == 1 && controller.sections[0].title == nil)
        #expect(Set(controller.rows.map(\.id)) == identities && controller.selectedID == selected)
        controller.order = .titleDescending
        #expect(controller.rows.first?.result.resourceTitle == "Zeta")
        controller.order = .mostHits
        #expect(controller.rows.map { $0.result.hitCount } == [3,3,3,2,2,1])
        controller.grouping = .resource; controller.order = .source
        #expect(controller.rows.map(\.result.resourceID) == Array(repeating: resources[0].id, count: 4) + Array(repeating: resources[1].id, count: 2))
        #expect(report.results == original && Set(controller.rows.map(\.id)) == identities)
        let sameTitles = resources.map { source in
            LibraryResource(location: source.location, title: "Same title", byteCount: source.byteCount, format: source.format, support: source.support, provenance: source.provenance)
        }
        let sameReport = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: sameTitles, query: SearchQueryParser.parse("needle"))
        controller.setResults(sameReport.results)
        #expect(controller.sections.count == 2 && Set(controller.sections.map(\.id)).count == 2)
    }
    @Test func NavigationVisitsLastHitsOutsideTheFirstSnippetAndStopsAtBothEnds() async throws {
        _ = NSApplication.shared
        let text = "😀 needle " + String(repeating: "context ", count: 50) + "needle " + String(repeating: "context ", count: 50) + "needle"
        let fixture = try AuthoredReaderFixture(documents: [[text]]); defer { fixture.remove() }
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: fixture.resources, query: SearchQueryParser.parse("needle"))
        let result = try #require(report.results.first), controller = WorkspaceSearchResultsController(); controller.setResults(report.results)
        #expect(controller.selectedIndex == 0 && !controller.canPrevious)
        controller.previous(); #expect(controller.selectedIndex == 0)
        controller.next(); controller.next()
        let row = try #require(controller.selected)
        #expect(controller.selectedIndex == 2 && !controller.canNext && row.parts?.match == "needle")
        #expect(result.hits[2].range.location > result.snippet.rangeInArticle.upperBound)
        let reader = ReaderSession(resource: fixture.resources[0]); reader.loadSearchResult(row.result, focus: row.focus); try await settle(reader)
        #expect(reader.error == nil && reader.selectedText == "needle" && reader.selectedRange == result.hits[2].range.nsRange)
        controller.next(); #expect(controller.selectedID == row.id)
        controller.setResults([]); controller.next(); controller.previous()
        #expect(controller.rows.isEmpty && controller.selectedID == nil && !controller.canNext && !controller.canPrevious)
    }
    @Test func MixedTitleAndReaderOccurrencesOpenTheirOwnIndependentCoordinates() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(chapterBody: "<span id='a1'></span><p>needle body</p><span id='a2'></span><p>other</p>"); defer { fixture.remove() }
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [fixture.resource], query: SearchQueryParser.parse("title:Chapter OR body:needle"))
        let result = try #require(report.results.first), controller = WorkspaceSearchResultsController(); controller.setResults([result])
        #expect(controller.rows.count == 2 && controller.rows[0].parts?.match == "needle" && controller.rows[1].parts?.match == "Chapter")
        let metadata = controller.rows[1], reader = ReaderSession(resource: fixture.resource)
        reader.loadSearchResult(result, focus: metadata.focus); try await settle(reader)
        let page = try #require(reader.page?.oeb), path = try #require(page.book.path(for: page.url))
        let projection = try await ReaderOEBTextSource.shared.read(book: page.book, path: path, viewport: .init())
        try reader.acceptOEBProjection(projection.text, at: page.url)
        #expect(reader.error == nil && reader.selectedRange.length == 0 && metadata.field == .title)
        #expect(result.hits[0].range != result.externalHits[0].range)
    }
    @Test func PresentationBudgetOmissionsAndNegativeOnlyMatchesRemainNavigableWithoutFakeHits() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["needle " + String(repeating: "context ", count: 50) + "needle"]]); defer { fixture.remove() }
        let service = LibrarySearchService(provider: WorkspaceSearchReader())
        let report = try await service.search(resources: fixture.resources, query: SearchQueryParser.parse("needle"), budget: .init(snippetUTF16: 8, maximumContextUTF16: 8))
        let controller = WorkspaceSearchResultsController(); controller.setResults(report.results)
        #expect(report.coverageComplete && !report.contextCoverageComplete && controller.rows.count == 2 && controller.rows[1].parts == nil)
        controller.next(); let row = try #require(controller.selected)
        let reader = ReaderSession(resource: fixture.resources[0]); reader.loadSearchResult(row.result, focus: row.focus); try await settle(reader)
        #expect(reader.selectedRange == report.results[0].hits[1].range.nsRange)
        let negative = try await service.search(resources: fixture.resources, query: SearchQueryParser.parse("NOT absent"))
        controller.setResults(negative.results)
        #expect(controller.rows.count == 1 && controller.rows[0].isSummary && controller.rows[0].result.hitCount == 0)
        #expect(controller.rows[0].focus.isValid(for: negative.results[0]))
    }
    @Test func ForgedFocusAndChangedSourcesCannotApplyASelection() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredReaderFixture(documents: [["needle needle"]]); defer { fixture.remove() }
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: fixture.resources, query: SearchQueryParser.parse("needle"))
        let result = try #require(report.results.first), reader = ReaderSession(resource: fixture.resources[0])
        reader.loadSearchResult(result, focus: .reader(.init(location: 100, length: 6)))
        #expect(reader.error != nil && reader.page == nil && !reader.isLoading)
        var data = try Data(contentsOf: fixture.resources[0].location); data.append(0); try data.write(to: fixture.resources[0].location)
        reader.loadSearchResult(result, focus: .reader(result.hits[1].range)); try await settle(reader)
        #expect(reader.error != nil && reader.selectedRange.length == 0)
    }
    @Test func ContextPartsKeepOriginalUnicodeAndExplicitPartialMatchIndicators() {
        let text = "😀 a\u{301} needle tail", range = (text as NSString).range(of: "needle")
        let parts = WorkspaceSearchContextParts.make(text: text, extent: .init(location: 10, length: text.utf16.count), focus: .init(location: range.location + 10, length: range.length), omittedBefore: true, omittedAfter: false)
        #expect(parts?.before == "😀 a\u{301} " && parts?.match == "needle" && parts?.after == " tail" && parts?.omittedBefore == true)
        let partial = WorkspaceSearchContextParts.make(text: "eed", extent: .init(location: 1, length: 3), focus: .init(location: 0, length: 6), omittedBefore: true, omittedAfter: true)
        #expect(partial?.match == "eed" && partial?.partialStart == true && partial?.partialEnd == true)
        #expect(WorkspaceSearchContextParts.make(text: "😀", extent: .init(location: 0, length: 2), focus: .init(location: 1, length: 1), omittedBefore: false, omittedAfter: false) == nil)
    }
    @Test func ReplacingReportClearsSelectionButKeepsPresentationPreferences() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["needle needle"]]); defer { fixture.remove() }
        let controller = WorkspaceSearchController()
        controller.presentation.order = .titleDescending; controller.presentation.grouping = .none; controller.presentation.layout = .aligned
        controller.resourceID = fixture.resources[0].id; controller.query = "needle"; controller.run(fixture.resources)
        for _ in 0..<2000 { if !controller.isSearching { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.coverageComplete && controller.presentation.rows.count == 2)
        controller.presentation.next(); #expect(controller.presentation.selectedIndex == 1)
        controller.clear()
        #expect(controller.presentation.rows.isEmpty && controller.presentation.selectedID == nil)
        #expect(controller.presentation.order == .titleDescending && controller.presentation.layout == .aligned && controller.presentation.grouping == .none)
    }
}
