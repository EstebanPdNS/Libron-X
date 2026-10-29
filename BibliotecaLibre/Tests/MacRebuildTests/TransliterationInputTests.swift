import Testing
import Foundation
import LibronixCore
@testable import MacRebuild

struct TransliterationInputTests {
    @Test func textConvertsWithoutChangingTheInput() {
        let greek = "Αὑ", hebrew = "בִי"
        #expect(TransliterationInput.convert(greek, language: .greek) == "Hau")
        #expect(TransliterationInput.convert(hebrew, language: .hebrew) == "bî")
        #expect(greek == "Αὑ" && hebrew == "בִי")
    }
    @Test func boundedInputRejectsOversizedAndNullCharacters() {
        #expect(TransliterationInput.convert(String(repeating: "a", count: 4097), language: .greek) == nil)
        #expect(TransliterationInput.convert("a\0b", language: .hebrew) == nil)
        #expect(TransliterationInput.convert("", language: .greek) == "")
        let maximum = String(repeating: "ב", count: 4096)
        #expect(TransliterationInput.convert(maximum, language: .hebrew)?.count == 4096)
    }
    @Test func queryTreatsOperatorsQuotesAndBackslashesAsLiteralText() throws {
        let text = "λόγος AND \"שלום\" \\ 😀"
        let query = try #require(TransliterationInput.literalQuery(text))
        guard case .phrase(let operand) = query.expression else { Issue.record("Expected one literal phrase"); return }
        #expect(operand.text == text)
        let source = "prefix " + text + " suffix"
        let result = try TextSearchEngine.search(query: query, in: source)
        #expect(result.hitCount == 1)
        #expect((source as NSString).substring(with: result.hits[0].range.nsRange) == text)
        #expect(try TextSearchEngine.search(query: query, in: "λόγος AND שלום").matchesQuery == false)
    }
    @Test func queryUsesTheSearchBoundaryAndRejectsBlankOrInvalidInput() {
        #expect(TransliterationInput.literalQuery(" \n\t") == nil)
        #expect(TransliterationInput.literalQuery("a\0b") == nil)
        #expect(TransliterationInput.literalQuery(String(repeating: "א", count: 512)) != nil)
        #expect(TransliterationInput.literalQuery(String(repeating: "א", count: 513)) == nil)
    }
    @MainActor @Test func searchTransferKeepsTheDraftAndScopeAndRemovesStaleFilters() throws {
        let draft = TransliterationController(), search = WorkspaceSearchController()
        draft.input = "λόγος"; search.query = "old"; search.searchField = .heading
        search.approximatePhrase = true; search.bibleVerses = true
        search.scope.kind = .library; search.limits.results = 77
        let query = try #require(draft.convertedQuery)
        #expect(draft.prepareSearch(query, in: search))
        #expect(search.query == "\"logos\"")
        #expect(search.searchField == nil && search.wordFilter == nil && !search.approximatePhrase && !search.bibleVerses)
        #expect(search.scope.kind == .library && search.limits.results == 77)
        #expect(search.phase == .idle && search.report == nil)
        #expect(draft.input == "λόγος" && draft.output == "logos")
        let original = try #require(draft.originalQuery)
        #expect(draft.prepareSearch(original, in: search))
        #expect(search.query == "\"λόγος\"" && draft.input == "λόγος")
    }
}
