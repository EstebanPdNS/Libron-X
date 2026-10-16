import Foundation

public struct TextSearchOptions: Hashable, Sendable {
    public var caseSensitive: Bool
    public var diacriticSensitive: Bool
    public var wholeWords: Bool
    public var maximumTextUTF16: Int
    public var maximumHits: Int
    public var maximumMatchAttempts: Int
    public var maximumDocuments: Int

    public init(caseSensitive: Bool = false, diacriticSensitive: Bool = true,
                wholeWords: Bool = true, maximumTextUTF16: Int = 16 * 1_024 * 1_024,
                maximumHits: Int = 10_000, maximumMatchAttempts: Int = 100_000,
                maximumDocuments: Int = 10_000) {
        self.caseSensitive = caseSensitive
        self.diacriticSensitive = diacriticSensitive
        self.wholeWords = wholeWords
        self.maximumTextUTF16 = maximumTextUTF16
        self.maximumHits = maximumHits
        self.maximumMatchAttempts = maximumMatchAttempts
        self.maximumDocuments = maximumDocuments
    }
}

public struct TextSearchHit: Hashable, Sendable {
    public let range: SearchTextRange
    /// Query operands that contribute to this range, including their source spans.
    public let operands: [SearchTextOperand]
}

public struct TextSearchResult: Hashable, Sendable {
    public let matchesQuery: Bool
    public let hits: [TextSearchHit]
    public let textUTF16Count: Int
    public var hitCount: Int { hits.count }
}

public struct SearchTextDocument: Hashable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct TextSearchDocumentResult: Hashable, Sendable {
    public let documentID: String
    public let result: TextSearchResult
}

public enum TextSearchError: Error, LocalizedError, Equatable, Sendable {
    case invalidLimits, textLimit, hitLimit, workLimit, documentLimit, duplicateDocumentID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "Search limits must be positive and within the engine's safety bounds."
        case .textLimit: "Document exceeds the UTF-16 text budget."
        case .hitLimit: "Search exceeds the hit budget; no incomplete result is returned."
        case .workLimit: "Search exceeds the match-attempt budget; no incomplete result is returned."
        case .documentLimit: "Search exceeds the document budget."
        case let .duplicateDocumentID(id): "Search received a repeated document identity: \(id)."
        }
    }
}

/// An independent, document-scoped text evaluator. It does not read legacy
/// indexes, infer lemma/Strong matches or claim the original engine's semantics.
public enum TextSearchEngine {
    public static func search(query: SearchQuery, in text: String,
                              options: TextSearchOptions = TextSearchOptions(),
                              checkCancellation: (@Sendable () throws -> Void)? = nil) throws -> TextSearchResult {
        try validate(options)
        let length = text.utf16.count
        guard length <= options.maximumTextUTF16 else { throw TextSearchError.textLimit }
        try Task.checkCancellation()
        try checkCancellation?()
        var evaluator = try Evaluator(text: text, options: options, checkCancellation: checkCancellation)
        let outcome = try evaluator.evaluate(query.expression)
        let hits = outcome.matches ? try evaluator.makeHits(outcome.evidence) : []
        return TextSearchResult(matchesQuery: outcome.matches, hits: hits, textUTF16Count: length)
    }

    /// Each document is a separate boolean scope; AND cannot join different books.
    /// Input order is preserved. Negative-only matches can legitimately have no hits.
    public static func search(query: SearchQuery, in documents: [SearchTextDocument],
                              options: TextSearchOptions = TextSearchOptions(),
                              checkCancellation: (@Sendable () throws -> Void)? = nil) throws -> [TextSearchDocumentResult] {
        try validate(options)
        try Task.checkCancellation()
        try checkCancellation?()
        guard documents.count <= options.maximumDocuments else { throw TextSearchError.documentLimit }
        var ids = Set<String>()
        for document in documents {
            try Task.checkCancellation()
            try checkCancellation?()
            guard ids.insert(document.id).inserted else { throw TextSearchError.duplicateDocumentID(document.id) }
        }
        var output: [TextSearchDocumentResult] = []
        for document in documents {
            let result = try search(query: query, in: document.text, options: options, checkCancellation: checkCancellation)
            if result.matchesQuery { output.append(.init(documentID: document.id, result: result)) }
        }
        return output
    }

    private static func validate(_ options: TextSearchOptions) throws {
        guard options.maximumTextUTF16 > 0, options.maximumTextUTF16 <= 64 * 1_024 * 1_024,
              options.maximumHits > 0, options.maximumHits <= 1_000_000,
              options.maximumMatchAttempts > 0, options.maximumMatchAttempts <= 10_000_000,
              options.maximumDocuments > 0, options.maximumDocuments <= 100_000 else {
            throw TextSearchError.invalidLimits
        }
    }

    private struct Evidence: Hashable {
        let range: SearchTextRange
        let operand: SearchTextOperand
    }
    private struct Outcome {
        let matches: Bool
        // Evidence for the actual boolean outcome. Inversion can recover the
        // positive evidence of double negation or NOT (A OR NOT B).
        let evidence: Set<Evidence>
    }
    private struct Evaluator {
        let text: NSString
        let options: TextSearchOptions
        let checkCancellation: (@Sendable () throws -> Void)?
        let wordStarts: Set<Int>
        let wordEnds: Set<Int>
        var attempts = 0
        var cache: [String: [SearchTextRange]] = [:]

        init(text source: String, options: TextSearchOptions,
             checkCancellation: (@Sendable () throws -> Void)?) throws {
            text = source as NSString
            self.options = options
            self.checkCancellation = checkCancellation
            let boundaries = try Self.wordBoundaries(source, checkCancellation: checkCancellation)
            wordStarts = boundaries.starts
            wordEnds = boundaries.ends
        }

        mutating func evaluate(_ expression: SearchExpression) throws -> Outcome {
            try Task.checkCancellation()
            try checkCancellation?()
            switch expression {
            case let .term(operand), let .phrase(operand):
                let ranges = try find(operand.text)
                return Outcome(matches: !ranges.isEmpty,
                               evidence: Set(ranges.map { Evidence(range: $0, operand: operand) }))
            case let .conjunction(lhs, rhs):
                let left = try evaluate(lhs)
                let right = try evaluate(rhs)
                let matched = left.matches && right.matches
                // Only branches contributing to the actual outcome carry evidence.
                var evidence = Set<Evidence>()
                if left.matches == matched { evidence.formUnion(left.evidence) }
                if right.matches == matched { evidence.formUnion(right.evidence) }
                return Outcome(matches: matched, evidence: evidence)
            case let .disjunction(lhs, rhs):
                let left = try evaluate(lhs)
                let right = try evaluate(rhs)
                let matched = left.matches || right.matches
                var evidence = Set<Evidence>()
                if left.matches == matched { evidence.formUnion(left.evidence) }
                if right.matches == matched { evidence.formUnion(right.evidence) }
                return Outcome(matches: matched, evidence: evidence)
            case let .negation(child):
                let result = try evaluate(child)
                return Outcome(matches: !result.matches, evidence: result.evidence)
            }
        }

        mutating func find(_ needle: String) throws -> [SearchTextRange] {
            if let cached = cache[needle] { return cached }
            var comparison: NSString.CompareOptions = []
            if !options.caseSensitive { comparison.insert(.caseInsensitive) }
            if !options.diacriticSensitive { comparison.insert(.diacriticInsensitive) }
            let firstIsWord = needle.unicodeScalars.first.map(Self.isWordScalar) ?? false
            let lastIsWord = needle.unicodeScalars.last.map(Self.isWordScalar) ?? false
            var cursor = 0
            var matches: [SearchTextRange] = []
            while cursor < text.length {
                try Task.checkCancellation()
                try checkCancellation?()
                attempts += 1
                guard attempts <= options.maximumMatchAttempts else { throw TextSearchError.workLimit }
                let found = text.range(of: needle, options: comparison,
                                       range: NSRange(location: cursor, length: text.length - cursor), locale: nil)
                guard found.location != NSNotFound else { break }
                // Diacritic-insensitive NSString matching can omit a trailing mark.
                // Returning the complete original grapheme prevents broken highlights.
                let composed = text.rangeOfComposedCharacterSequences(for: found)
                let range = SearchTextRange(location: composed.location, length: composed.length)
                let startsAtWord = !firstIsWord || wordStarts.contains(range.location)
                let endsAtWord = !lastIsWord || wordEnds.contains(range.upperBound)
                if !options.wholeWords || (startsAtWord && endsAtWord) {
                    matches.append(range)
                    guard matches.count <= options.maximumHits else { throw TextSearchError.hitLimit }
                }
                // Nonoverlapping matches for each operand; no zero-length operand
                // reaches this evaluator through the parser.
                cursor = max(range.upperBound, found.location + max(found.length, 1))
            }
            cache[needle] = matches
            return matches
        }

        func makeHits(_ evidence: Set<Evidence>) throws -> [TextSearchHit] {
            let grouped = Dictionary(grouping: evidence, by: \.range)
            guard grouped.count <= options.maximumHits else { throw TextSearchError.hitLimit }
            return grouped.keys.sorted {
                $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
            }.map { range in
                let operands = Set(grouped[range, default: []].map(\.operand)).sorted {
                    if $0.sourceRange.location != $1.sourceRange.location {
                        return $0.sourceRange.location < $1.sourceRange.location
                    }
                    return $0.text < $1.text
                }
                return TextSearchHit(range: range, operands: operands)
            }
        }

        static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar) || scalar == "_"
        }

        /// Explicit lexical boundaries, not a substitute for language-specific
        /// segmentation/stemming. Internal straight/curly apostrophes join a word.
        static func wordBoundaries(_ source: String,
                                   checkCancellation: (@Sendable () throws -> Void)?) throws -> (starts: Set<Int>, ends: Set<Int>) {
            let scalars = Array(source.unicodeScalars)
            var starts = Set<Int>(), ends = Set<Int>()
            var position = 0
            var inWord = false
            for (index, scalar) in scalars.enumerated() {
                if index.isMultiple(of: 1_024) {
                    try Task.checkCancellation()
                    try checkCancellation?()
                }
                let apostrophe = (scalar == "'" || scalar == "’")
                    && index > 0 && index + 1 < scalars.count
                    && isWordScalar(scalars[index - 1]) && isWordScalar(scalars[index + 1])
                let word = isWordScalar(scalar) || apostrophe
                if word && !inWord { starts.insert(position) }
                if !word && inWord { ends.insert(position) }
                inWord = word
                position += scalar.value > 0xFFFF ? 2 : 1
            }
            if inWord { ends.insert(position) }
            return (starts, ends)
        }
    }
}
