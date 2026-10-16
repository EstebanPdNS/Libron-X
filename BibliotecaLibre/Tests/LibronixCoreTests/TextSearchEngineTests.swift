import Foundation
import Testing
@testable import LibronixCore

@Suite struct TextSearchEngineTests {
    private func search(_ query: String, _ text: String,
                        options: TextSearchOptions = .init()) throws -> TextSearchResult {
        try TextSearchEngine.search(query: SearchQueryParser.parse(query), in: text, options: options)
    }
    private func substrings(_ result: TextSearchResult, in text: String) -> [String] {
        result.hits.map { (text as NSString).substring(with: $0.range.nsRange) }
    }

    @Test func documentScopedBooleansReturnOnlySatisfyingPositiveEvidence() throws {
        let text = "faith hope love"
        #expect(try search("faith AND hope", text).hitCount == 2)
        #expect(try search("faith AND fear", text).matchesQuery == false)
        let disjunction = try search("faith OR (hope AND fear)", text)
        #expect(substrings(disjunction, in: text) == ["faith"])
        #expect(try search("faith AND NOT fear", text).hitCount == 1)
        #expect(try search("NOT faith", text).matchesQuery == false)
        let negative = try search("NOT fear", text)
        #expect(negative.matchesQuery)
        #expect(negative.hits.isEmpty)
        #expect(try search("NOT NOT faith", text).hitCount == 1)
        let nested = try search("NOT (fear OR NOT hope)", text)
        #expect(substrings(nested, in: text) == ["hope"])
    }

    @Test func documentsKeepIndependentScopesIdentityAndInputOrder() throws {
        let query = try SearchQueryParser.parse("faith AND hope")
        let documents = [SearchTextDocument(id: "a", text: "faith"),
                         SearchTextDocument(id: "b", text: "hope"),
                         SearchTextDocument(id: "c", text: "faith hope"),
                         SearchTextDocument(id: "d", text: "hope faith")]
        let results = try TextSearchEngine.search(query: query, in: documents)
        #expect(results.map(\.documentID) == ["c", "d"])
        #expect(throws: TextSearchError.duplicateDocumentID("a")) {
            try TextSearchEngine.search(query: query, in: [documents[0], documents[0]])
        }
    }

    @Test func canonicalEquivalentGreekSpanishHebrewAndSupplementaryPrefixesUseUTF16() throws {
        let text = "😀λόγος café café שָׁלוֹם"
        let greek = try search("λόγος", text)
        #expect(greek.hits.first?.range == SearchTextRange(location: 2, length: 6))
        #expect(substrings(greek, in: text) == ["λόγος"])
        let spanish = try search("café", text)
        #expect(substrings(spanish, in: text) == ["café", "café"])
        #expect(try search("שלום", text).hits.isEmpty)
        let hebrew = try search("שלום", text, options: .init(diacriticSensitive: false))
        #expect(substrings(hebrew, in: text) == ["שָׁלוֹם"])
        let unmarked = try search("cafe", text, options: .init(diacriticSensitive: false))
        #expect(substrings(unmarked, in: text) == ["café", "café"])
        #expect(unmarked.hits.last?.range.length == 5)
    }

    @Test func caseFoldingWithDifferentLengthsPreservesOriginalRanges() throws {
        let text = "😀Straße STRASSE"
        let insensitive = try search("strasse", text)
        #expect(substrings(insensitive, in: text) == ["Straße", "STRASSE"])
        #expect(insensitive.hits.first?.range == SearchTextRange(location: 2, length: 6))
        #expect(try search("strasse", text, options: .init(caseSensitive: true)).hits.isEmpty)
        #expect(try search("STRASSE", text, options: .init(caseSensitive: true)).hitCount == 1)
    }

    @Test func wholeWordBoundariesTreatMarksAndInternalApostrophesAsPartOfWords() throws {
        let text = "art article cart art. can't cant can can’t 123 23"
        #expect(substrings(try search("art", text), in: text) == ["art", "art"])
        #expect(substrings(try search("can", text), in: text) == ["can"])
        #expect(substrings(try search("can't", text), in: text) == ["can't"])
        #expect(substrings(try search("23", text), in: text) == ["23"])
        #expect(try search("art", text, options: .init(wholeWords: false)).hitCount == 4)
    }

    @Test func phrasesKeepLiteralWhitespacePunctuationAndOriginalText() throws {
        let text = "Holy Spirit. Holy  Spirit. Holy\nSpirit. say \"amen\". 😀"
        #expect(substrings(try search("\"Holy Spirit\"", text), in: text) == ["Holy Spirit"])
        #expect(substrings(try search(#""say \"amen\"""#, text), in: text) == [#"say "amen""#])
        #expect(substrings(try search("\"😀\"", text), in: text) == ["😀"])
        #expect(try search("\"Holy, Spirit\"", text).hits.isEmpty)
        #expect(try search("\"aba\"", "ababa", options: .init(wholeWords: false)).hitCount == 1)
    }

    @Test func repeatedClausesMergeByRangeWithoutLosingOperandSourceSpans() throws {
        let result = try search("love OR love OR \"love\"", "love love")
        #expect(result.hitCount == 2)
        #expect(result.hits.allSatisfy { $0.operands.count == 3 })
        #expect(result.hits[0].operands.map(\.sourceRange.location) == [0, 8, 16])
        #expect(result.hits.map(\.range.location) == [0, 5])
    }

    @Test func boundedFailuresNeverReturnAnIncompleteResult() throws {
        #expect(throws: TextSearchError.hitLimit) {
            try search("a", "a a a", options: .init(maximumHits: 2))
        }
        #expect(throws: TextSearchError.hitLimit) {
            try search("a OR b", "a b", options: .init(maximumHits: 1))
        }
        #expect(throws: TextSearchError.workLimit) {
            try search("a", "aa aa a", options: .init(maximumMatchAttempts: 2))
        }
        #expect(throws: TextSearchError.textLimit) {
            try search("a", "😀a", options: .init(maximumTextUTF16: 2))
        }
        #expect(throws: TextSearchError.invalidLimits) {
            try search("a", "a", options: .init(maximumHits: Int.max))
        }
        let query = try SearchQueryParser.parse("a")
        #expect(throws: TextSearchError.documentLimit) {
            try TextSearchEngine.search(query: query,
                in: [.init(id: "a", text: "a"), .init(id: "b", text: "a")],
                options: .init(maximumDocuments: 1))
        }
    }

    @Test func emptyDocumentsAndCancellationHaveExplicitOutcomes() throws {
        #expect(try search("a", "").matchesQuery == false)
        #expect(try search("NOT a", "").matchesQuery == true)
        let query = try SearchQueryParser.parse("a")
        #expect(throws: CancellationError.self) {
            try TextSearchEngine.search(query: query, in: "a a", checkCancellation: { throw CancellationError() })
        }
    }

    @Test func compoundNegationAndParenthesesCoverEveryPresenceCombination() throws {
        for faith in [false, true] {
            for hope in [false, true] {
                for fear in [false, true] {
                    let text = [(faith, "faith"), (hope, "hope"), (fear, "fear")]
                        .filter(\.0).map(\.1).joined(separator: " ")
                    #expect(try search("(faith OR hope) AND NOT fear", text).matchesQuery == ((faith || hope) && !fear))
                    #expect(try search("NOT (faith OR NOT hope)", text).matchesQuery == (!faith && hope))
                    #expect(try search("NOT (faith AND NOT hope)", text).matchesQuery == (!faith || hope))
                }
            }
        }
    }

    @Test func cancellationOfTheActualSwiftTaskIsRespected() async throws {
        let query = try SearchQueryParser.parse("faith")
        let gate = SearchCancellationGate()
        let task = Task {
            await gate.wait()
            return try TextSearchEngine.search(query: query, in: "faith hope")
        }
        task.cancel()
        await gate.release()
        do { _ = try await task.value; Issue.record("Cancelled search returned a result") }
        catch is CancellationError {}
        catch { Issue.record("Unexpected cancellation error: \(error)") }
    }
}

private actor SearchCancellationGate {
    var released = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
