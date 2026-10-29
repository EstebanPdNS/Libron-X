import Foundation
import Testing
@testable import LibronixCore

struct WordSearchPuzzleTests {
    @Test func generatedPuzzleRetainsWordsAndValidatesBothSelectionDirections() throws {
        let puzzle = try WordSearchGenerator.generate(words: ["palabra", "camino", "luz", "fe", "amor"], size: 10, seed: 42)
        try puzzle.validate()
        #expect(puzzle == (try WordSearchGenerator.generate(words: ["palabra", "camino", "luz", "fe", "amor"], size: 10, seed: 42)))
        for placement in puzzle.placements {
            let start = (placement.row, placement.column)
            let end = (start.0 + (placement.word.count - 1) * placement.rowStep, start.1 + (placement.word.count - 1) * placement.columnStep)
            #expect(puzzle.matches(placement, from: start, to: end))
            #expect(puzzle.matches(placement, from: end, to: start))
            #expect(!puzzle.matches(placement, from: start, to: start))
        }
        #expect(try JSONDecoder().decode(WordSearchPuzzle.self, from: JSONEncoder().encode(puzzle)) == puzzle)
    }
    @Test func rejectsInvalidWordsAndSizes() throws {
        for words in [[], ["a"], ["a b"], ["alma", "ALMA"], ["123"]] {
            #expect(throws: WordSearchError.self) { try WordSearchGenerator.generate(words: words, size: 8, seed: 1) }
        }
        #expect(throws: WordSearchError.invalid) { try WordSearchGenerator.generate(words: ["faith"], size: 5, seed: 1) }
        let puzzle = try WordSearchGenerator.generate(words: ["FE", "AMÉN"], size: 6, seed: 7)
        try puzzle.validate()
        let malformed = WordSearchPlacement(word: "FE", row: Int.max, column: 0, rowStep: 1, columnStep: 0)
        let damaged = WordSearchPuzzle(size: puzzle.size, grid: puzzle.grid, placements: [malformed])
        #expect(throws: WordSearchError.invalid) { try damaged.validate() }
        #expect(!damaged.matches(malformed, from: (0, 0), to: (1, 0)))
    }
}
