import Foundation

/// Banded Levenshtein over original extended grapheme clusters. One best end
/// per eligible start: lowest distance, then closest length, then shorter span.
/// Normalized comparison tokens never replace source UTF-16 coordinates.
enum ApproximateTextMatcher {
    static func validate(_ expression: SearchExpression, distance: Int) throws {
        switch expression {
        case .term(let operand), .phrase(let operand):
            guard operand.text.count > distance, operand.text.count <= 256 else { throw TextSearchError.invalidApproximateOperand }
        case .conjunction(let a, let b), .disjunction(let a, let b), .proximity(_, let a, let b):
            try validate(a, distance: distance); try validate(b, distance: distance)
        case .negation(let a), .field(_, let a): try validate(a, distance: distance)
        }
    }
    static func find(_ needle: String, in source: String, options: TextSearchOptions,
                     startAllowed: (Int) -> Bool, endAllowed: (Int) -> Bool,
                     work: inout Int, checkCancellation: (@Sendable () throws -> Void)?) throws -> [SearchTextRange] {
        let k = options.maximumEditDistance
        var folding: String.CompareOptions = []
        if !options.caseSensitive { folding.insert(.caseInsensitive) }
        if !options.diacriticSensitive { folding.insert(.diacriticInsensitive) }
        let locale = Locale(identifier: "en_US_POSIX")
        func token(_ character: Character) -> String {
            String(character).folding(options: folding, locale: locale).precomposedStringWithCanonicalMapping
        }
        let query = needle.map(token), m = query.count
        var tokens: [String] = [], offsets = [0]
        var offset = 0
        for (index, character) in source.enumerated() {
            if index.isMultiple(of: 1024) { try Task.checkCancellation(); try checkCancellation?() }
            tokens.append(token(character)); offset += character.utf16.count; offsets.append(offset)
        }
        var hits: [SearchTextRange] = []
        let infinity = k + 1
        for start in tokens.indices where startAllowed(offsets[start]) {
            try Task.checkCancellation(); try checkCancellation?()
            work += 1; guard work <= options.maximumMatchAttempts else { throw TextSearchError.workLimit }
            let available = min(m + k, tokens.count - start)
            if available < m - k { continue }
            var previous = (0...m).map { min($0, infinity) }
            var best: (distance: Int, length: Int)?
            for length in 1...available {
                var current = Array(repeating: infinity, count: m + 1)
                current[0] = min(length, infinity)
                let low = max(1, length - k), high = min(m, length + k)
                if low > high { break }
                var minimum = current[0]
                for column in low...high {
                    work += 1; guard work <= options.maximumMatchAttempts else { throw TextSearchError.workLimit }
                    if work.isMultiple(of: 256) { try Task.checkCancellation(); try checkCancellation?() }
                    let substitution = previous[column - 1] + (query[column - 1] == tokens[start + length - 1] ? 0 : 1)
                    current[column] = min(infinity, substitution, previous[column] + 1, current[column - 1] + 1)
                    minimum = min(minimum, current[column])
                }
                let distance = current[m]
                if distance <= k, endAllowed(offsets[start + length]) {
                    if best == nil || distance < best!.distance || (distance == best!.distance && abs(length - m) < abs(best!.length - m)) {
                        best = (distance, length)
                    }
                    if distance == 0 { break }
                }
                if minimum > k { break }
                previous = current
            }
            if let best {
                hits.append(.init(location: offsets[start], length: offsets[start + best.length] - offsets[start]))
                guard hits.count <= options.maximumHits else { throw TextSearchError.hitLimit }
            }
        }
        return hits
    }
}
