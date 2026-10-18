import Foundation
import Testing
@testable import LibronixCore

@Suite struct ApproximateTextSearchTests {
    private func search(_ literal: String, _ text: String, edits: Int = 1, whole: Bool = true) throws -> TextSearchResult {
        let quoted = "\"" + literal.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return try TextSearchEngine.search(query: SearchQueryParser.parse(quoted), in: text,
            options: .init(wholeWords: whole, maximumMatchAttempts: 1_000_000, maximumEditDistance: edits))
    }
    @Test func exactInsertDeleteSubstituteAndUnrelatedPhrasesHaveDiscriminatingResults() throws {
        for phrase in ["in the beginning", "in the begining", "in the begginning", "in the beginninX"] {
            let result = try search(phrase, "prefix in the beginning suffix")
            #expect(result.hitCount == 1)
            #expect(result.hits.first?.range == .init(location: 7, length: 16))
        }
        #expect(try search("in another beginning", "in the beginning").matchesQuery == false)
        #expect(try search("faiht", "faith", edits: 1).hitCount == 0)
        #expect(try search("faiht", "faith", edits: 2).hitCount == 1)
        let exact = try search("in the begining", "in the beginning", edits: 0)
        #expect(!exact.matchesQuery)
    }
    @Test func UnicodeGraphemesPreserveReaderUTF16AndRespectComparisonOptions() throws {
        let text = "😀 cafe\u{301} 👨‍👩‍👧‍👦 fin"
        let expected = (text as NSString).range(of: "cafe\u{301} 👨‍👩‍👧‍👦")
        let result = try search("café 👩", text)
        #expect(result.hits.map(\.range) == [.init(location: expected.location, length: expected.length)])
        let query = try SearchQueryParser.parse("\"CAFÉ test\"")
        var options = TextSearchOptions(maximumEditDistance: 1)
        #expect(try TextSearchEngine.search(query: query, in: "cafe test", options: options).hitCount == 1)
        options.caseSensitive = true
        #expect(try TextSearchEngine.search(query: query, in: "cafe test", options: options).hitCount == 0)
        options.caseSensitive = false; options.diacriticSensitive = false
        #expect(try TextSearchEngine.search(query: query, in: "cafe text", options: options).hitCount == 1)
        options.diacriticSensitive = true
        #expect(try TextSearchEngine.search(query: query, in: "cafe text", options: options).hitCount == 0)
    }
    @Test func WholeWordAndLiteralOperatorsRemainExplicit() throws {
        #expect(try search("cat", "cat cats scatter").hitCount == 2)
        #expect(try search("cat", "scatter", whole: false).hitCount > 0)
        #expect(try search("faith AND hope", "faith AND hXpe").hitCount == 1)
        #expect(try search("faith AND hope", "faith hope").hitCount == 0)
        #expect(try search("don't", "don't dont don’t").hitCount == 3)
        #expect(try search("alpha beta", "alpha\nbeta").hitCount == 1)
    }
    @Test func ValidationBudgetsCancellationAndOverlappingStartsNeverSilentlyTruncate() throws {
        let query = try SearchQueryParser.parse("faith")
        #expect(throws: TextSearchError.invalidLimits) { try TextSearchEngine.search(query: query, in: "faith", options: .init(maximumEditDistance: 4)) }
        #expect(throws: TextSearchError.invalidApproximateOperand) { try search("a", "abc") }
        #expect(throws: TextSearchError.invalidApproximateOperand) { try search(String(repeating: "a", count: 257), "abc") }
        #expect(throws: TextSearchError.approximateTextLimit) { try search("abc", String(repeating: "a", count: 1_048_577)) }
        #expect(throws: TextSearchError.workLimit) { try TextSearchEngine.search(query: query, in: "faith", options: .init(maximumMatchAttempts: 2, maximumEditDistance: 1)) }
        #expect(throws: TextSearchError.hitLimit) { try TextSearchEngine.search(query: query, in: "faith faith", options: .init(maximumHits: 1, maximumEditDistance: 1)) }
        #expect(throws: CancellationError.self) { try TextSearchEngine.search(query: query, in: "faith", options: .init(maximumEditDistance: 1), checkCancellation: { throw CancellationError() }) }
        #expect(try search("aba", "ababa", whole: false).hits.contains { $0.range.location == 2 })
    }
    @Test func FieldsMetadataAndPositionOperatorsUseOnlyActualMatchedSpans() throws {
        let fields = SearchFieldDirectory(regions: [.body: [.init(location: 0, length: 5), .init(location: 6, length: 4)]], externalValues: [.title: ["Owned title"]])
        let options = TextSearchOptions(maximumEditDistance: 1)
        let metadata = try TextSearchEngine.search(query: SearchQueryParser.parse("title:\"Owned tXtle\""), in: "faith hope", options: options, fields: fields)
        #expect(metadata.hits.isEmpty && metadata.externalHits.count == 1 && metadata.externalHits[0].range == .init(location: 0, length: 11))
        #expect(try TextSearchEngine.search(query: SearchQueryParser.parse("body:\"faith hope\""), in: "faith hope", options: options, fields: fields).hitCount == 0)
        let positional = try TextSearchEngine.search(query: SearchQueryParser.parse("faXth BEFORE/0 hXpe"), in: "faith hope", options: options)
        #expect(positional.hitCount == 2 && positional.hits.map(\.range) == [.init(location: 0, length: 5), .init(location: 6, length: 4)])
        #expect(try TextSearchEngine.search(query: SearchQueryParser.parse("faXth AND NOT xyzzy"), in: "faith hope", options: options).hitCount == 1)
    }
    @Test func BandedSearchMatchesIndependentFullMatrixOracleAcrossAllSmallWindows() throws {
        func distance(_ a: [Character], _ b: [Character]) -> Int {
            var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in 0...a.count { matrix[i][0] = i }
            for j in 0...b.count { matrix[0][j] = j }
            for i in 1...a.count { for j in 1...b.count {
                matrix[i][j] = min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            } }
            return matrix[a.count][b.count]
        }
        for number in 0..<128 {
            let text = (0..<7).map { number & (1 << $0) == 0 ? "a" : "b" }.joined()
            for (query, k) in [("aba", 1), ("abab", 2)] {
                var expected: [SearchTextRange] = []
                let chars = Array(text), needle = Array(query)
                for start in chars.indices {
                    var candidates: [(distance: Int, length: Int)] = []
                    for end in (start + 1)...chars.count {
                        let cost = distance(needle, Array(chars[start..<end]))
                        if cost <= k { candidates.append((cost, end - start)) }
                    }
                    candidates.sort { a,b in
                        if a.distance != b.distance { return a.distance < b.distance }
                        if abs(a.length - needle.count) != abs(b.length - needle.count) { return abs(a.length - needle.count) < abs(b.length - needle.count) }
                        return a.length < b.length
                    }
                    if let best = candidates.first { expected.append(.init(location: start, length: best.length)) }
                }
                #expect(try search(query, text, edits: k, whole: false).hits.map(\.range) == expected)
            }
        }
    }
    @Test func WarmLiteralIndexCannotExcludeApproximateOnlyArticles() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["in the beginning", "an unrelated ending"]); defer { fixture.remove() }
        let source = PersistentLibrarySearchTests.Source(), query = try SearchQueryParser.parse("\"in the begining\"")
        let provider = PersistentLibrarySearchProvider(source: source, directory: fixture.cache)
        let exact = try await LibrarySearchService(provider: provider).search(resources: [fixture.resource], query: query)
        #expect(exact.coverageComplete && exact.results.isEmpty)
        await source.blockReads()
        let warm = PersistentLibrarySearchProvider(source: source, directory: fixture.cache)
        let approximate = try await LibrarySearchService(provider: warm).search(resources: [fixture.resource], query: query, options: .init(maximumEditDistance: 1))
        #expect(approximate.coverageComplete && approximate.results.count == 1 && approximate.counters.articlesRuledOutByIndex == 0)
        #expect(approximate.results[0].hits[0].range == .init(location: 0, length: 16))
        #expect(await warm.metrics.sourceReads == 0)
    }
    @Test func ResourceWorkExhaustionIsReportedAsPartialInsteadOfCompleteNoHits() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["faith", "hope"]); defer { fixture.remove() }
        let report = try await LibrarySearchService(provider: PersistentLibrarySearchTests.Source()).search(
            resources: [fixture.resource], query: SearchQueryParser.parse("faith"),
            options: .init(maximumMatchAttempts: 2, maximumEditDistance: 1))
        #expect(!report.coverageComplete && report.results.isEmpty && report.counters.articlesFailed == 2)
        #expect(report.resourceReports[0].errors.count == 2)
    }

    @Test func ExplicitDOMWordBoundariesPreserveOffsetsWithoutPhantomWhitespaceWords() throws {
        let query = try SearchQueryParser.parse("faith")
        #expect(try TextSearchEngine.search(query: query, in: "faithhope").hitCount == 0)
        #expect(try TextSearchEngine.search(query: query, in: "faithhope", lexicalBreaks: [5]).hits[0].range == .init(location: 0, length: 5))
        #expect(try TextSearchEngine.search(query: SearchQueryParser.parse("faXth"), in: "faithhope", options: .init(maximumEditDistance: 1), lexicalBreaks: [5]).hitCount == 1)
        #expect(try TextSearchEngine.search(query: SearchQueryParser.parse("faith BEFORE/0 hope"), in: "faith hope", lexicalBreaks: [5,6]).hitCount == 2)
        #expect(try TextSearchEngine.search(query: SearchQueryParser.parse("body:(faith BEFORE/0 hope)"), in: "faithhope", fields: .init(regions: [.body: [.init(location: 0, length: 9)]]), lexicalBreaks: [5]).hitCount == 2)
        for points in [[0], [9], [6,5], [5,5]] {
            #expect(throws: TextSearchError.invalidLexicalBoundaries) { try TextSearchEngine.search(query: query, in: "faithhope", lexicalBreaks: points) }
        }
        #expect(throws: TextSearchError.invalidLexicalBoundaries) { try TextSearchEngine.search(query: query, in: "😀faith", lexicalBreaks: [1]) }
    }
    @Test func CachedDOMBoundariesRemainValidatedAndBackwardCompatible() async throws {
        let fixture = try PersistentLibrarySearchTests.Fixture(["faithhope"]); defer { fixture.remove() }
        try fixture.replace([.init(text: "faithhope", lexicalBreaks: [5])])
        let source = PersistentLibrarySearchTests.Source(), query = try SearchQueryParser.parse("faith")
        let provider = PersistentLibrarySearchProvider(source: source, directory: fixture.cache)
        let first = try await LibrarySearchService(provider: provider).search(resources: [fixture.resource], query: query)
        #expect(first.coverageComplete && first.results.count == 1)
        await source.blockReads()
        let again = try await LibrarySearchService(provider: PersistentLibrarySearchProvider(source: source, directory: fixture.cache)).search(resources: [fixture.resource], query: query)
        #expect(again.results == first.results && again.coverageComplete)
        let old = Data(#"{"text":"old","warnings":[],"bibleVerses":[],"referenceAnchors":[]}"#.utf8)
        #expect(try JSONDecoder().decode(LibrarySearchDecodedArticle.self, from: old).lexicalBreaks == nil)
    }

}
