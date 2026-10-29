import Foundation

public struct WordSearchPlacement: Codable, Equatable, Sendable {
    public let word: String
    public let row: Int
    public let column: Int
    public let rowStep: Int
    public let columnStep: Int
}
public struct WordSearchPuzzle: Codable, Equatable, Sendable {
    public let size: Int
    public let grid: [[String]]
    public let placements: [WordSearchPlacement]
    public func validate() throws {
        guard (6...20).contains(size), grid.count == size, grid.allSatisfy({ $0.count == size && $0.allSatisfy { $0.count == 1 && $0.first?.isLetter == true } }),
              !placements.isEmpty, placements.count <= 30, Set(placements.map(\.word)).count == placements.count else { throw WordSearchError.invalid }
        for placement in placements {
            let letters = Array(placement.word).map(String.init)
            guard (2...size).contains(letters.count), (0..<size).contains(placement.row), (0..<size).contains(placement.column),
                  (-1...1).contains(placement.rowStep), (-1...1).contains(placement.columnStep),
                  placement.rowStep != 0 || placement.columnStep != 0 else { throw WordSearchError.invalid }
            for (index, letter) in letters.enumerated() {
                let row = placement.row + index * placement.rowStep, column = placement.column + index * placement.columnStep
                guard (0..<size).contains(row), (0..<size).contains(column), grid[row][column] == letter else { throw WordSearchError.invalid }
            }
        }
    }
    /// Reverse dragging selects the same occurrence; unrelated occurrences do
    /// not count as the generated solution.
    public func matches(_ placement: WordSearchPlacement, from start: (Int, Int), to end: (Int, Int)) -> Bool {
        let count = placement.word.count
        guard placements.contains(placement), (6...20).contains(size), (2...size).contains(count),
              (0..<size).contains(placement.row), (0..<size).contains(placement.column),
              (-1...1).contains(placement.rowStep), (-1...1).contains(placement.columnStep) else { return false }
        let first = (placement.row, placement.column)
        let last = (first.0 + (count - 1) * placement.rowStep, first.1 + (count - 1) * placement.columnStep)
        return (start == first && end == last) || (start == last && end == first)
    }
}
public enum WordSearchError: Error, LocalizedError, Equatable {
    case invalid, cannotPlace
    public var errorDescription: String? {
        switch self {
        case .invalid: "Las palabras o la cuadrícula no son válidas."
        case .cannotPlace: "No se pudieron colocar todas las palabras. Reduce la lista o aumenta la cuadrícula."
        }
    }
}
public enum WordSearchGenerator {
    /// Words consist of Unicode letters only. Exact accent marks are preserved;
    /// each grapheme occupies one square. Seeded generation is reproducible.
    public static func generate(words: [String], size: Int, seed: UInt64) throws -> WordSearchPuzzle {
        guard (6...20).contains(size), !words.isEmpty, words.count <= 30 else { throw WordSearchError.invalid }
        let normalized = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.uppercased() }
        guard Set(normalized).count == normalized.count, normalized.allSatisfy({ word in
            (2...size).contains(word.count) && word.allSatisfy(\.isLetter)
        }) else { throw WordSearchError.invalid }
        var random = SeededGenerator(state: seed), cells = Array(repeating: Array(repeating: "", count: size), count: size)
        var result: [WordSearchPlacement] = []
        let directions = [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)]
        for word in normalized.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }) {
            let letters = Array(word).map(String.init)
            var candidates: [(Int, Int, Int, Int)] = []
            for row in 0..<size { for column in 0..<size { for (dr, dc) in directions {
                let endRow = row + (letters.count - 1) * dr, endColumn = column + (letters.count - 1) * dc
                guard (0..<size).contains(endRow), (0..<size).contains(endColumn) else { continue }
                if letters.enumerated().allSatisfy({ index, letter in
                    let current = cells[row + index * dr][column + index * dc]
                    return current.isEmpty || current == letter
                }) { candidates.append((row, column, dr, dc)) }
            } } }
            guard !candidates.isEmpty else { throw WordSearchError.cannotPlace }
            let candidate = candidates[Int(random.next() % UInt64(candidates.count))]
            for (index, letter) in letters.enumerated() { cells[candidate.0 + index * candidate.2][candidate.1 + index * candidate.3] = letter }
            result.append(.init(word: word, row: candidate.0, column: candidate.1, rowStep: candidate.2, columnStep: candidate.3))
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
        for row in 0..<size { for column in 0..<size where cells[row][column].isEmpty { cells[row][column] = alphabet[Int(random.next() % UInt64(alphabet.count))] } }
        let puzzle = WordSearchPuzzle(size: size, grid: cells, placements: result); try puzzle.validate(); return puzzle
    }
    private struct SeededGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
    }
}
