import Foundation
import Testing
@testable import LibronixCore

struct BibleSearchDistributionTests {
    actor Source: LibrarySearchContentProvider {
        let articles: [String: LibrarySearchDecodedArticle]
        init(_ articles: [String: LibrarySearchDecodedArticle]) { self.articles = articles }
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            .init(articles: [.init(sectionOrdinal: 0, title: "Authored chapter")])
        }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
            try #require(articles[resource.id])
        }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {}
    }
    private func resource(_ name: String) -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/authored/" + name + ".LSF"), title: name, byteCount: 0,
              format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
    }
    private func article(_ verses: [(String, String)]) throws -> LibrarySearchDecodedArticle {
        var text = "😀 Heading\n", intervals: [LibrarySearchBibleVerse] = []
        for (reference, body) in verses {
            intervals.append(.init(reference: reference, normalizedReference: try #require(LegacyPassageQuery.parse(reference)).normalizedKey,
                range: .init(location: text.utf16.count, length: body.utf16.count)))
            text += body
        }
        return .init(text: text, bibleVerses: intervals)
    }
    @Test func countsAndDestinationsStaySeparateForBooksChaptersAndEditions() async throws {
        let a = resource("A"), b = resource("B")
        let source = try Source([a.id: article([("Ge1:1", "light light\n"), ("Ge1:2", "light\n"),
            ("Ge2:1", "light\n"), ("John3:16", "light\n")]), b.id: article([("Ge1:1", "light\n"), ("Ge1:2", "dark\n")])])
        let report = try await LibrarySearchService(provider: source).search(resources: [a,b], query: SearchQueryParser.parse("light"), unit: .bibleVerse)
        let books = try BibleSearchDistribution.build(report: report, resources: [a,b], grouping: .book)
        #expect(books.complete && books.groups.count == 3)
        #expect(books.groups[0].title == "ge" && books.groups[0].results.count == 3)
        #expect(books.groups[0].observedOccurrences == 4 && books.groups[0].retainedOccurrences == 4)
        #expect(books.groups[1].title == "jn" && books.groups[2].id.resourceID == b.id)
        #expect(books.groups.flatMap(\.results) == report.results)
        let chapters = try BibleSearchDistribution.build(report: report, resources: [a,b], grouping: .chapter)
        #expect(chapters.groups.map(\.title) == ["ge 1", "ge 2", "jn 3", "ge 1"])
        #expect(chapters.groups[0].results.map(\.id) == Array(report.results.prefix(2)).map(\.id))
        let incomplete = try BibleSearchDistribution.build(report: report, resources: [a,b], grouping: .book, scopeComplete: false)
        #expect(!incomplete.complete)
    }
    @Test func overlappingRangesRetainIndependentMembersAndZeroCounts() async throws {
        let a = resource("A"), source = try Source([a.id: article([("Ge1:1", "light light\n"), ("Ge1:2", "light\n")])])
        let report = try await LibrarySearchService(provider: source).search(resources: [a], query: SearchQueryParser.parse("light"), unit: .bibleVerse)
        let groups = try BibleSearchDistribution.build(report: report, resources: [a], grouping: .ranges,
            ranges: ["Ge1:1", "Ge1:1-2", "John3:16"]).groups
        #expect(groups.map { $0.results.count } == [1,2,0])
        #expect(groups.map(\.retainedOccurrences) == [2,3,0])
        #expect(groups[0].results.first?.id == groups[1].results.first?.id)
        #expect(throws: BibleSearchDistributionError.invalidRanges) {
            try BibleSearchDistribution.build(report: report, resources: [a], grouping: .ranges, ranges: ["Ge1", "Ge1"])
        }
        #expect(throws: BibleSearchDistributionError.invalidRanges) {
            try BibleSearchDistribution.build(report: report, resources: [a], grouping: .ranges)
        }
    }
    @Test func partialReportsNeverTurnObservedMatchesIntoRetainedHitsOrCompleteCoverage() async throws {
        let a = resource("A"), source = try Source([a.id: article([("Ge1:1", "light light\n"), ("Ge1:2", "light\n")])])
        let service = LibrarySearchService(provider: source)
        let partial = try await service.search(resources: [a], query: SearchQueryParser.parse("light"), unit: .bibleVerse,
            budget: .init(maximumOccurrences: 1))
        let distribution = try BibleSearchDistribution.build(report: partial, resources: [a], grouping: .book)
        #expect(!distribution.complete && distribution.groups.count == 1)
        #expect(distribution.groups[0].observedOccurrences == 2 && distribution.groups[0].retainedOccurrences == 1)
        let articles = try await service.search(resources: [a], query: SearchQueryParser.parse("light"))
        #expect(throws: BibleSearchDistributionError.requiresVerseResults) {
            try BibleSearchDistribution.build(report: articles, resources: [a], grouping: .book)
        }
        #expect(throws: BibleSearchDistributionError.invalidResults) {
            try BibleSearchDistribution.build(report: partial, resources: [], grouping: .book)
        }
    }
}
