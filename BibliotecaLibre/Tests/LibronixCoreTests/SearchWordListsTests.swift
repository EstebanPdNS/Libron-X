import Foundation
import Testing
@testable import LibronixCore

struct SearchWordListsTests {
    @Test func filtersRealSearchMatchesWithoutInterpretingTermsAsOperators() throws {
        let filter = SearchWordFilter(include: ["hope", "peace"], exclude: ["fear"])
        let query = try SearchQueryParser.parse(filter.compile("faith"))
        #expect(try TextSearchEngine.search(query: query, in: "faith and hope").matchesQuery)
        #expect(!(try TextSearchEngine.search(query: query, in: "faith and hope and fear").matchesQuery))
        #expect(!(try TextSearchEngine.search(query: query, in: "faith alone").matchesQuery))
        let literal = try SearchQueryParser.parse(SearchWordFilter(include: ["OR"]).compile("faith"))
        #expect(try TextSearchEngine.search(query: literal, in: "faith OR").matchesQuery)
    }
    @Test func validationAndEscapesAreBounded() throws {
        let filter = SearchWordFilter(include: ["quoted \"text\"", "a\\b"])
        _ = try SearchQueryParser.parse(filter.compile("faith"))
        #expect(throws: (any Error).self) { try SearchWordFilter(include: [""]).compile("faith") }
        var state = SearchWordLists(); state.lists = [.init(name: "A", terms: ["faith", "hope"])]
        try state.validate(); state.lists[0].terms.append("FAITH")
        #expect(throws: (any Error).self) { try state.validate() }
    }
}
