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
    case verseContextRequired, unsupportedVerseBoundary

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "Search limits must be positive and within the engine's safety bounds."
        case .textLimit: "Document exceeds the UTF-16 text budget."
        case .hitLimit: "Search exceeds the hit budget; no incomplete result is returned."
        case .workLimit: "Search exceeds the match-attempt budget; no incomplete result is returned."
        case .documentLimit: "Search exceeds the document budget."
        case .verseContextRequired: "Verse distance requires verified source verse intervals covering the operands."
        case .unsupportedVerseBoundary: "Verse distance across different chapters or editions requires an explicit source versification map."
        case let .duplicateDocumentID(id): "Search received a repeated document identity: \(id)."
        }
    }
}

/// An independent, document-scoped text evaluator. It does not read legacy
/// indexes, infer lemma/Strong matches or claim the original engine's semantics.
public enum TextSearchEngine {
    public static func search(query: SearchQuery, in text: String,
                              options: TextSearchOptions = TextSearchOptions(),
                              verses: [LibrarySearchBibleVerse]? = nil,
                              checkCancellation: (@Sendable () throws -> Void)? = nil) throws -> TextSearchResult {
        try validate(options)
        let length = text.utf16.count
        guard length <= options.maximumTextUTF16 else { throw TextSearchError.textLimit }
        try Task.checkCancellation()
        try checkCancellation?()
        if query.expression.requiresVerseContext, verses == nil || (verses?.isEmpty == true && !text.isEmpty) { throw TextSearchError.verseContextRequired }
        var evaluator = try Evaluator(text: text, options: options, verses: verses, checkCancellation: checkCancellation)
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
    private struct PositionalSpan: Hashable {
        let range: SearchTextRange
        let evidence: Set<Evidence>
    }
    private struct VerseCoordinate {
        let range: SearchTextRange
        let group: String
        let number: Int
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
        var sortedWordStarts: [Int] = []
        var sortedWordEnds: [Int] = []
        var wordCoordinatesReady = false
        let verseCoordinates: [VerseCoordinate]
        var attempts = 0
        var cache: [String: [SearchTextRange]] = [:]

        init(text source: String, options: TextSearchOptions, verses: [LibrarySearchBibleVerse]?,
             checkCancellation: (@Sendable () throws -> Void)?) throws {
            text = source as NSString
            self.options = options
            self.checkCancellation = checkCancellation
            let boundaries = try Self.wordBoundaries(source, checkCancellation: checkCancellation)
            wordStarts = boundaries.starts
            wordEnds = boundaries.ends
            if let verses {
                try BibleVerseText.validate(verses, in: source)
                var previous: [String:Int] = [:]
                verseCoordinates = try verses.map { verse in
                    guard let reference = LegacyPassageQuery.parse(verse.reference) else { throw LibrarySearchError.invalidVerseDirectory }
                    let raw = verse.reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let edition = raw.hasPrefix("bible+") ? String(raw.split(separator: ".")[0]) : "bible"
                    let group = edition + ":" + reference.sourceBookKey + ":" + String(reference.chapter)
                    if let last = previous[group], last >= reference.verse { throw LibrarySearchError.invalidVerseDirectory }
                    previous[group] = reference.verse
                    return VerseCoordinate(range: verse.range, group: group, number: reference.verse)
                }
            } else { verseCoordinates = [] }
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
            case .proximity:
                let spans = try positionalSpans(expression)
                return Outcome(matches: !spans.isEmpty, evidence: spans.reduce(into: Set<Evidence>()) { $0.formUnion($1.evidence) })
            case let .negation(child):
                let result = try evaluate(child)
                return Outcome(matches: !result.matches, evidence: result.evidence)
            }
        }

        mutating func positionalSpans(_ expression: SearchExpression) throws -> [PositionalSpan] {
            try Task.checkCancellation(); try checkCancellation?()
            switch expression {
            case .term(let operand), .phrase(let operand):
                return try find(operand.text).map { .init(range: $0, evidence: [.init(range: $0, operand: operand)]) }
            case .disjunction(let a, let b):
                let left = try positionalSpans(a), right = try positionalSpans(b)
                let result = Set(left + right)
                guard result.count <= options.maximumHits else { throw TextSearchError.hitLimit }
                return result.sorted { $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location }
            case .proximity(let op, let a, let b):
                let left = try positionalSpans(a), right = try positionalSpans(b)
                var result = Set<PositionalSpan>()
                for lhs in left {
                    for rhs in right {
                        try Task.checkCancellation(); try checkCancellation?()
                        attempts += 1
                        guard attempts <= options.maximumMatchAttempts else { throw TextSearchError.workLimit }
                        // Distinct, nonoverlapping witnesses: one occurrence can
                        // never satisfy both sides of a repeated operand.
                        let forward = lhs.range.upperBound <= rhs.range.location
                        let backward = rhs.range.upperBound <= lhs.range.location
                        guard forward || backward else { continue }
                        guard op.direction == .either || (op.direction == .before && forward) || (op.direction == .after && backward) else { continue }
                        let first = forward ? lhs : rhs, last = forward ? rhs : lhs
                        if let maximum = op.maximumDistance {
                            let distance: Int
                            switch op.unit {
                            case .characters: distance = last.range.location - first.range.upperBound
                            case .words:
                                if !wordCoordinatesReady {
                                    sortedWordStarts = wordStarts.sorted(); sortedWordEnds = wordEnds.sorted()
                                    wordCoordinatesReady = true
                                }
                                distance = max(0, Self.upperBound(sortedWordEnds, last.range.location) - Self.lowerBound(sortedWordStarts, first.range.upperBound))
                            case .verses:
                                guard let firstStart = verse(at: first.range.location), let x = verse(at: first.range.upperBound - 1),
                                      let y = verse(at: last.range.location), let lastEnd = verse(at: last.range.upperBound - 1) else { throw TextSearchError.verseContextRequired }
                                guard firstStart.group == x.group, x.group == y.group, y.group == lastEnd.group else { throw TextSearchError.unsupportedVerseBoundary }
                                distance = y.number - x.number
                                guard distance >= 0 else { throw LibrarySearchError.invalidVerseDirectory }
                            }
                            guard distance <= maximum else { continue }
                        }
                        result.insert(.init(range: .init(location: first.range.location, length: last.range.upperBound - first.range.location), evidence: lhs.evidence.union(rhs.evidence)))
                        guard result.count <= options.maximumHits else { throw TextSearchError.hitLimit }
                    }
                }
                return result.sorted { $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location }
            case .conjunction, .negation:
                throw SearchQueryError(.invalidProximityOperand, range: .init(location:0,length:0), "A positional operand cannot be AND or NOT.")
            }
        }
        func verse(at position: Int) -> VerseCoordinate? {
            var low = 0, high = verseCoordinates.count
            while low < high {
                let mid = low + (high - low) / 2
                if verseCoordinates[mid].range.location <= position { low = mid + 1 } else { high = mid }
            }
            let index = low - 1
            guard verseCoordinates.indices.contains(index), position < verseCoordinates[index].range.upperBound else { return nil }
            return verseCoordinates[index]
        }
        static func lowerBound(_ values: [Int], _ target: Int) -> Int {
            var low = 0, high = values.count
            while low < high { let mid = low + (high - low) / 2; if values[mid] < target { low = mid + 1 } else { high = mid } }
            return low
        }
        static func upperBound(_ values: [Int], _ target: Int) -> Int {
            var low = 0, high = values.count
            while low < high { let mid = low + (high - low) / 2; if values[mid] <= target { low = mid + 1 } else { high = mid } }
            return low
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
