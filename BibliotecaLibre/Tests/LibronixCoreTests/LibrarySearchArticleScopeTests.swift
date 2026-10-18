import Foundation
import Testing
@testable import LibronixCore

struct LibrarySearchArticleScopeTests {
    actor Provider: LibrarySearchContentProvider {
        let text: String
        let ranges: [SearchTextRange]
        init(_ text: String, _ ranges: [SearchTextRange]) { self.text = text; self.ranges = ranges }
        func supports(_ resource: LibraryResource) async -> Bool { true }
        func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
            .init(articles: ranges.indices.map { .init(sectionOrdinal: $0, title: String($0)) })
        }
        func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor, prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
            .init(text: text, searchRange: ranges[article.sectionOrdinal])
        }
        func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {}
    }
    private var resource: LibraryResource {
        .init(location: URL(fileURLWithPath: "/owned/scope.epub"), title: "Owned", byteCount: 0, format: .epub, support: .metadataOnly, provenance: .fileName)
    }
    @Test func articleBoundariesKeepFullPageHashesAndOffsetsWithoutJoiningBooleanTerms() async throws {
        let first = "😀 faith ", second = "hope café"
        let text = first + second
        let provider = Provider(text, [.init(location: 0, length: first.utf16.count), .init(location: first.utf16.count, length: second.utf16.count)])
        let service = LibrarySearchService(provider: provider)
        let report = try await service.search(resources: [resource], query: SearchQueryParser.parse("café"))
        #expect(report.coverageComplete && report.results.count == 1)
        let result = try #require(report.results.first)
        #expect(result.sectionOrdinal == 1 && result.hits.first?.range.location == (first + "hope ").utf16.count)
        #expect(result.decodedTextSHA256 == LibrarySearchService.textFingerprint(text))
        #expect(result.snippet.text == second && result.snippet.rangeInArticle.location == first.utf16.count)
        let and = try await service.search(resources: [resource], query: SearchQueryParser.parse("faith AND hope"))
        #expect(and.results.isEmpty && and.coverageComplete)
        let phrase = try await service.search(resources: [resource], query: SearchQueryParser.parse("\"faith hope\""))
        #expect(phrase.results.isEmpty && phrase.coverageComplete)
        let not = try await service.search(resources: [resource], query: SearchQueryParser.parse("NOT faith"))
        #expect(not.results.map(\.sectionOrdinal) == [1] && not.results[0].hits.isEmpty)
    }
    @Test func invalidOrSplitUnicodeRangesReportErrorsInsteadOfSearchingAnotherArticle() async throws {
        for range in [SearchTextRange(location: -1, length: 1), .init(location: 0, length: Int.max),
                      .init(location: 1, length: 1), .init(location: 3, length: 1)] {
            let service = LibrarySearchService(provider: Provider("😀 a\u{301} faith", [range]))
            let report = try await service.search(resources: [resource], query: SearchQueryParser.parse("faith"))
            #expect(!report.coverageComplete && report.counters.articlesFailed == 1 && report.results.isEmpty)
        }
    }
    @Test func thePortableDefaultStillReportsEPUBAsUnavailable() async throws {
        let report = try await LibrarySearchService().search(resources: [resource], query: SearchQueryParser.parse("faith"))
        #expect(report.counters.resourcesIncompatible == 1 && !report.coverageComplete)
    }
}
