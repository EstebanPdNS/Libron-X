import Foundation
import Testing
@testable import LibronixCore

@Suite struct SearchOccurrenceContextTests {
    @Test func EveryFarApartOccurrenceGetsItsOwnBoundedOriginalContext() async throws {
        let text = "😀 needle " + String(repeating: "left ", count: 80) + "needle " + String(repeating: "right ", count: 80) + "needle a\u{301}"
        let fixture = try PersistentLibrarySearchTests.Fixture([text]); defer { fixture.remove() }
        let report = try await LibrarySearchService(provider: PersistentLibrarySearchTests.Source()).search(
            resources: [fixture.resource], query: SearchQueryParser.parse("needle"), budget: .init(snippetUTF16: 40))
        let result = try #require(report.results.first)
        #expect(report.coverageComplete && report.contextCoverageComplete && result.hits.count == 3 && result.contexts.count == 3)
        #expect(result.contexts.map(\.range) == result.hits.map(\.range))
        #expect(result.hits[2].range.location > result.snippet.rangeInArticle.upperBound)
        for context in result.contexts {
            #expect(context.snippet.text.utf16.count <= 40)
            #expect((text as NSString).substring(with: context.snippet.rangeInArticle.nsRange) == context.snippet.text)
            #expect(Range(context.snippet.rangeInArticle.nsRange, in: text) != nil)
            let local = try #require(context.snippet.highlightRanges.first)
            #expect((context.snippet.text as NSString).substring(with: local.nsRange) == "needle")
        }
        #expect(result.decodedTextSHA256 == LibrarySearchService.textFingerprint(text))
    }
    @Test func ContextBudgetOmissionsDoNotDropHitsOrPretendSearchCoverageWasPartial() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["needle " + String(repeating: "x ", count: 100) + "needle"]); defer { fixture.remove() }
        let service = LibrarySearchService(provider: PersistentLibrarySearchTests.Source()), query = try SearchQueryParser.parse("needle")
        for maximum in [0,8] {
            let report = try await service.search(resources: [fixture.resource], query: query, budget: .init(snippetUTF16: 8, maximumContextUTF16: maximum))
            #expect(report.coverageComplete && report.limitReason == nil && !report.contextCoverageComplete)
            #expect(report.counters.occurrencesReturned == 2 && report.results[0].hits.count == 2)
            #expect(report.results[0].contexts.reduce(0) { $0 + $1.snippet.text.utf16.count } <= maximum)
            #expect(report.results[0].contextsOmitted == (maximum == 0 ? 2 : 1))
        }
        for maximum in [-1,64 * 1024 * 1024 + 1] {
            await #expect(throws: LibrarySearchError.invalidBudget) { try await service.search(resources: [fixture.resource], query: query, budget: .init(maximumContextUTF16: maximum)) }
        }
    }
    @Test func ArticleAndVerseScopesClipContextsWithoutRewritingPageCoordinates() async throws {
        let text = "😀header faith FIRST\nhope SECOND"
        let source = text as NSString, first = source.range(of: "faith FIRST\n"), second = source.range(of: "hope SECOND")
        let fixture = try PersistentLibrarySearchTests.Fixture([text]); defer { fixture.remove() }
        try fixture.replace([.init(text: text, bibleVerses: [
            .init(reference: "Ge1:1", normalizedReference: "ge 1:1", range: .init(location: first.location, length: first.length)),
            .init(reference: "Ge1:2", normalizedReference: "ge 1:2", range: .init(location: second.location, length: second.length))], searchRange: .init(location: first.location, length: source.length - first.location))])
        let report = try await LibrarySearchService(provider: PersistentLibrarySearchTests.Source()).search(resources: [fixture.resource], query: SearchQueryParser.parse("faith OR hope"), unit: .bibleVerse)
        #expect(report.coverageComplete && report.contextCoverageComplete && report.results.count == 2)
        for result in report.results {
            let verse = try #require(result.verseRange), context = try #require(result.contexts.first)
            #expect(context.snippet.rangeInArticle.location >= verse.location && context.snippet.rangeInArticle.upperBound <= verse.upperBound)
            #expect(!context.snippet.text.contains("header"))
            #expect((text as NSString).substring(with: context.snippet.rangeInArticle.nsRange) == context.snippet.text)
        }
    }
    @Test func NegativeAndMetadataOnlyResultsNeverAcquireInventedReaderContexts() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["body"]); defer { fixture.remove() }
        try fixture.replace([.init(text: "body", fieldDirectory: .init(regions: [.body: [.init(location: 0, length: 4)]], externalValues: [.title: ["needle"]]))])
        for query in ["NOT missing", "title:needle"] {
            let report = try await LibrarySearchService(provider: PersistentLibrarySearchTests.Source()).search(resources: [fixture.resource], query: SearchQueryParser.parse(query))
            #expect(report.coverageComplete && report.contextCoverageComplete && report.results.count == 1)
            #expect(report.results[0].hits.isEmpty && report.results[0].contexts.isEmpty)
        }
    }
}
