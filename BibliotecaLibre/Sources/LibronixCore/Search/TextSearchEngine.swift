import Foundation

public struct TextSearchOptions: Hashable, Sendable {
    public var maximumEditDistance: Int
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
                maximumDocuments: Int = 10_000, maximumEditDistance: Int = 0) {
        self.maximumEditDistance = maximumEditDistance
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

public struct TextSearchExternalHit: Hashable, Sendable {
    public let field: SearchField
    public let valueIndex: Int
    public let value: String
    public let range: SearchTextRange
    public let operands: [SearchTextOperand]
}

public struct TextSearchResult: Hashable, Sendable {
    public let matchesQuery: Bool
    public let hits: [TextSearchHit]
    public let textUTF16Count: Int
    public var externalHits: [TextSearchExternalHit] = []
    public var hitCount: Int { hits.count + externalHits.count }
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
    case invalidApproximateOperand, approximateTextLimit, invalidLexicalBoundaries
    case verseContextRequired, unsupportedVerseBoundary
    case fieldContextRequired, unsupportedField(SearchField), invalidFieldDirectory, nonPositionalField(SearchField)

    public var errorDescription: String? {
        switch self {
        case .invalidLexicalBoundaries: "Source word boundaries are invalid or exceed the boundary budget."
        case .invalidApproximateOperand: "Approximate operands must contain more grapheme clusters than the edit limit and at most 256 grapheme clusters."
        case .approximateTextLimit: "Approximate search supports at most 1048576 UTF-16 units per evaluated article or field value."
        case .invalidLimits: "Search limits must be positive and within the engine's safety bounds."
        case .textLimit: "Document exceeds the UTF-16 text budget."
        case .hitLimit: "Search exceeds the hit budget; no incomplete result is returned."
        case .workLimit: "Search exceeds the match-attempt budget; no incomplete result is returned."
        case .documentLimit: "Search exceeds the document budget."
        case .fieldContextRequired: "Field search requires a verified source field directory."
        case .unsupportedField(let field): "The source does not expose the requested field: \(field.rawValue)."
        case .nonPositionalField(let field): "The field has text outside reader coordinates and cannot be a proximity operand: \(field.rawValue)."
        case .invalidFieldDirectory: "The source field directory has invalid or ambiguous reader coordinates."
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
                              fields: SearchFieldDirectory? = nil, lexicalBreaks: [Int]? = nil,
                              checkCancellation: (@Sendable () throws -> Void)? = nil) throws -> TextSearchResult {
        try validate(options)
        if options.maximumEditDistance > 0 { try ApproximateTextMatcher.validate(query.expression, distance: options.maximumEditDistance) }
        let length = text.utf16.count
        guard length <= options.maximumTextUTF16 else { throw TextSearchError.textLimit }
        if options.maximumEditDistance > 0, length > 1_048_576 { throw TextSearchError.approximateTextLimit }
        try Task.checkCancellation()
        try checkCancellation?()
        if query.expression.requiresVerseContext, verses == nil || (verses?.isEmpty == true && !text.isEmpty) { throw TextSearchError.verseContextRequired }
        if !query.expression.requiredFields.isEmpty, fields == nil { throw TextSearchError.fieldContextRequired }
        if let fields {
            try fields.validate(in: text)
            for field in query.expression.requiredFields where !fields.supports(field) { throw TextSearchError.unsupportedField(field) }
        }
        try validateLexicalBreaks(lexicalBreaks, in: text)
        var evaluator = try Evaluator(text: text, options: options, verses: verses, fields: fields, lexicalBreaks: lexicalBreaks ?? [], checkCancellation: checkCancellation)
        let outcome = try evaluator.evaluate(query.expression)
        let hits = outcome.matches ? try evaluator.makeHits(outcome.evidence) : []
        let external = outcome.matches ? try evaluator.makeExternalHits(outcome.evidence) : []
        guard hits.count + external.count <= options.maximumHits else { throw TextSearchError.hitLimit }
        return TextSearchResult(matchesQuery: outcome.matches, hits: hits, textUTF16Count: length, externalHits: external)
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

    public static func validateLexicalBreaks(_ breaks: [Int]?, in text: String) throws {
        guard let breaks else { return }
        guard breaks.count <= 100_000 else { throw TextSearchError.invalidLexicalBoundaries }
        let source = text as NSString
        var previous = 0
        for position in breaks {
            guard position > previous, position < source.length,
                  source.rangeOfComposedCharacterSequence(at: position).location == position else { throw TextSearchError.invalidLexicalBoundaries }
            previous = position
        }
    }

    private static func validate(_ options: TextSearchOptions) throws {
        guard (0...3).contains(options.maximumEditDistance), options.maximumTextUTF16 > 0, options.maximumTextUTF16 <= 64 * 1_024 * 1_024,
              options.maximumHits > 0, options.maximumHits <= 1_000_000,
              options.maximumMatchAttempts > 0, options.maximumMatchAttempts <= 10_000_000,
              options.maximumDocuments > 0, options.maximumDocuments <= 100_000 else {
            throw TextSearchError.invalidLimits
        }
    }

    private enum Origin: Hashable { case reader, external(SearchField, Int) }
    private struct Evidence: Hashable {
        let range: SearchTextRange
        let operand: SearchTextOperand
        var origin: Origin = .reader
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
        let lexicalBreaks: [Int]
        let wordStarts: Set<Int>
        let wordEnds: Set<Int>
        var sortedWordStarts: [Int] = []
        var sortedWordEnds: [Int] = []
        var wordCoordinatesReady = false
        struct WordCoordinates { let starts: [Int]; let ends: [Int] }
        var fieldWordCoordinates: [SearchField: WordCoordinates] = [:]
        let verseCoordinates: [VerseCoordinate]
        var attempts = 0
        struct OperandKey: Hashable { let text: String; let field: SearchField? }
        let fields: SearchFieldDirectory?
        var cache: [OperandKey: [SearchTextRange]] = [:]
        struct ExternalKey: Hashable { let field: SearchField; let index: Int; let text: String }
        var externalCache: [ExternalKey: [SearchTextRange]] = [:]

        init(text source: String, options: TextSearchOptions, verses: [LibrarySearchBibleVerse]?, fields: SearchFieldDirectory?, lexicalBreaks: [Int] = [],
             checkCancellation: (@Sendable () throws -> Void)?) throws {
            text = source as NSString
            self.options = options
            self.fields = fields
            self.checkCancellation = checkCancellation
            let boundaries = try Self.wordBoundaries(source, checkCancellation: checkCancellation)
            let effective = lexicalBreaks.filter { position in
                guard !boundaries.starts.contains(position), !boundaries.ends.contains(position) else { return false }
                let index = String.Index(utf16Offset: position, in: source)
                guard let before = source[..<index].unicodeScalars.last, let after = source[index...].unicodeScalars.first else { return false }
                func wordPart(_ scalar: Unicode.Scalar) -> Bool { Self.isWordScalar(scalar) || scalar == "'" || scalar == "’" }
                return wordPart(before) && wordPart(after)
            }
            self.lexicalBreaks = effective
            wordStarts = boundaries.starts.union(effective)
            wordEnds = boundaries.ends.union(effective)
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

        mutating func evaluate(_ expression: SearchExpression, field: SearchField? = nil) throws -> Outcome {
            try Task.checkCancellation()
            try checkCancellation?()
            switch expression {
            case let .term(operand), let .phrase(operand):
                let ranges = try find(operand.text, field: field)
                var evidence = Set(ranges.map { Evidence(range: $0, operand: operand) })
                if let field { evidence.formUnion(try externalEvidence(operand, field: field)) }
                return Outcome(matches: !evidence.isEmpty, evidence: evidence)
            case let .conjunction(lhs, rhs):
                let left = try evaluate(lhs, field: field)
                let right = try evaluate(rhs, field: field)
                let matched = left.matches && right.matches
                // Only branches contributing to the actual outcome carry evidence.
                var evidence = Set<Evidence>()
                if left.matches == matched { evidence.formUnion(left.evidence) }
                if right.matches == matched { evidence.formUnion(right.evidence) }
                return Outcome(matches: matched, evidence: evidence)
            case let .disjunction(lhs, rhs):
                let left = try evaluate(lhs, field: field)
                let right = try evaluate(rhs, field: field)
                let matched = left.matches || right.matches
                var evidence = Set<Evidence>()
                if left.matches == matched { evidence.formUnion(left.evidence) }
                if right.matches == matched { evidence.formUnion(right.evidence) }
                return Outcome(matches: matched, evidence: evidence)
            case .field(let selected, let child):
                return try evaluate(child, field: selected)
            case .proximity:
                let spans = try positionalSpans(expression, field: field)
                return Outcome(matches: !spans.isEmpty, evidence: spans.reduce(into: Set<Evidence>()) { $0.formUnion($1.evidence) })
            case let .negation(child):
                let result = try evaluate(child, field: field)
                return Outcome(matches: !result.matches, evidence: result.evidence)
            }
        }

        mutating func positionalSpans(_ expression: SearchExpression, field: SearchField? = nil) throws -> [PositionalSpan] {
            try Task.checkCancellation(); try checkCancellation?()
            if let field, fields?.externalValues?[field]?.isEmpty == false { throw TextSearchError.nonPositionalField(field) }
            switch expression {
            case .term(let operand), .phrase(let operand):
                return try find(operand.text, field: field).map { .init(range: $0, evidence: [.init(range: $0, operand: operand)]) }
            case .field(let selected, let child):
                return try positionalSpans(child, field: selected)
            case .disjunction(let a, let b):
                let left = try positionalSpans(a, field: field), right = try positionalSpans(b, field: field)
                let result = Set(left + right)
                guard result.count <= options.maximumHits else { throw TextSearchError.hitLimit }
                return result.sorted { $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location }
            case .proximity(let op, let a, let b):
                let left = try positionalSpans(a, field: field), right = try positionalSpans(b, field: field)
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
                        let extent = SearchTextRange(location: first.range.location, length: last.range.upperBound - first.range.location)
                        if let field, fields?.containsWitness(extent, in: field) != true { continue }
                        if let maximum = op.maximumDistance {
                            let distance: Int
                            switch op.unit {
                            case .characters: distance = last.range.location - first.range.upperBound
                            case .words:
                                distance = try wordGap(from: first.range.upperBound, to: last.range.location, field: field)
                            case .verses:
                                guard let firstStart = verse(at: first.range.location), let x = verse(at: first.range.upperBound - 1),
                                      let y = verse(at: last.range.location), let lastEnd = verse(at: last.range.upperBound - 1) else { throw TextSearchError.verseContextRequired }
                                guard firstStart.group == x.group, x.group == y.group, y.group == lastEnd.group else { throw TextSearchError.unsupportedVerseBoundary }
                                distance = y.number - x.number
                                guard distance >= 0 else { throw LibrarySearchError.invalidVerseDirectory }
                            }
                            guard distance <= maximum else { continue }
                        }
                        result.insert(.init(range: extent, evidence: lhs.evidence.union(rhs.evidence)))
                        guard result.count <= options.maximumHits else { throw TextSearchError.hitLimit }
                    }
                }
                return result.sorted { $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location }
            case .conjunction, .negation:
                throw SearchQueryError(.invalidProximityOperand, range: .init(location:0,length:0), "A positional operand cannot be AND or NOT.")
            }
        }
        mutating func wordGap(from start: Int, to end: Int, field: SearchField?) throws -> Int {
            let coordinates: WordCoordinates
            if let field {
                if let cached = fieldWordCoordinates[field] { coordinates = cached }
                else {
                    var starts: [Int] = [], ends: [Int] = []
                    for range in fields?.regions[field] ?? [] {
                        let part = text.substring(with: range.nsRange)
                        let words = try Self.wordBoundaries(part, checkCancellation: checkCancellation)
                        let first = Self.upperBound(lexicalBreaks, range.location), last = Self.lowerBound(lexicalBreaks, range.upperBound)
                        let inner = lexicalBreaks[first..<last]
                        starts += Set(words.starts.map { $0 + range.location }).union(inner)
                        ends += Set(words.ends.map { $0 + range.location }).union(inner)
                    }
                    coordinates = .init(starts: starts.sorted(), ends: ends.sorted())
                    fieldWordCoordinates[field] = coordinates
                }
            } else {
                if !wordCoordinatesReady {
                    sortedWordStarts = wordStarts.sorted(); sortedWordEnds = wordEnds.sorted(); wordCoordinatesReady = true
                }
                coordinates = .init(starts: sortedWordStarts, ends: sortedWordEnds)
            }
            return max(0, Self.upperBound(coordinates.ends, end) - Self.lowerBound(coordinates.starts, start))
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

        mutating func find(_ needle: String, field: SearchField?) throws -> [SearchTextRange] {
            let key = OperandKey(text: needle, field: field)
            if let cached = cache[key] { return cached }
            let windows: [SearchTextRange]
            if let field {
                guard fields?.supports(field) == true else { throw TextSearchError.unsupportedField(field) }
                windows = fields?.regions[field] ?? []
            } else { windows = [.init(location: 0, length: text.length)] }
            if options.maximumEditDistance > 0 {
                let starts = wordStarts, ends = wordEnds, whole = options.wholeWords
                let firstIsWord = needle.unicodeScalars.first.map(Self.isWordScalar) ?? false
                let lastIsWord = needle.unicodeScalars.last.map(Self.isWordScalar) ?? false
                var ranges: [SearchTextRange] = []
                for window in windows {
                    let base = window.location, end = window.upperBound, logical = field != nil
                    let found = try ApproximateTextMatcher.find(needle, in: text.substring(with: window.nsRange), options: options,
                        startAllowed: { !whole || !firstIsWord || starts.contains(base + $0) || (logical && $0 == 0) },
                        endAllowed: { !whole || !lastIsWord || ends.contains(base + $0) || (logical && base + $0 == end) },
                        work: &attempts, checkCancellation: checkCancellation)
                    ranges += found.map { .init(location: base + $0.location, length: $0.length) }
                    guard ranges.count <= options.maximumHits else { throw TextSearchError.hitLimit }
                }
                cache[key] = ranges
                return ranges
            }
            var comparison: NSString.CompareOptions = []
            if !options.caseSensitive { comparison.insert(.caseInsensitive) }
            if !options.diacriticSensitive { comparison.insert(.diacriticInsensitive) }
            let firstIsWord = needle.unicodeScalars.first.map(Self.isWordScalar) ?? false
            let lastIsWord = needle.unicodeScalars.last.map(Self.isWordScalar) ?? false
            var matches: [SearchTextRange] = []
            for window in windows {
                var cursor = window.location
                while cursor < window.upperBound {
                    try Task.checkCancellation(); try checkCancellation?()
                    attempts += 1
                    guard attempts <= options.maximumMatchAttempts else { throw TextSearchError.workLimit }
                    let found = text.range(of: needle, options: comparison,
                        range: NSRange(location: cursor, length: window.upperBound - cursor), locale: nil)
                    guard found.location != NSNotFound else { break }
                    let composed = text.rangeOfComposedCharacterSequences(for: found)
                    let range = SearchTextRange(location: composed.location, length: composed.length)
                    let startsAtWord = !firstIsWord || wordStarts.contains(range.location) || (field != nil && range.location == window.location)
                    let endsAtWord = !lastIsWord || wordEnds.contains(range.upperBound) || (field != nil && range.upperBound == window.upperBound)
                    if range.location >= window.location, range.upperBound <= window.upperBound,
                       !options.wholeWords || (startsAtWord && endsAtWord) {
                        matches.append(range)
                        guard matches.count <= options.maximumHits else { throw TextSearchError.hitLimit }
                    }
                    cursor = max(range.upperBound, found.location + max(found.length, 1))
                }
            }
            cache[key] = matches
            return matches
        }

        mutating func externalEvidence(_ operand: SearchTextOperand, field: SearchField) throws -> Set<Evidence> {
            var result = Set<Evidence>()
            for (index, value) in (fields?.externalValues?[field] ?? []).enumerated() {
                let key = ExternalKey(field: field, index: index, text: operand.text)
                let found: [SearchTextRange]
                if let cached = externalCache[key] { found = cached }
                else {
                    guard value.utf16.count <= options.maximumTextUTF16 else { throw TextSearchError.textLimit }
                    let remaining = options.maximumMatchAttempts - attempts
                    guard remaining > 0 else { throw TextSearchError.workLimit }
                    var bounded = options; bounded.maximumMatchAttempts = remaining
                    var evaluator = try Evaluator(text: value, options: bounded, verses: nil, fields: nil, checkCancellation: checkCancellation)
                    found = try evaluator.find(operand.text, field: nil)
                    attempts += evaluator.attempts; externalCache[key] = found
                }
                result.formUnion(found.map { .init(range: $0, operand: operand, origin: .external(field, index)) })
                guard result.count <= options.maximumHits else { throw TextSearchError.hitLimit }
            }
            return result
        }
        func makeExternalHits(_ evidence: Set<Evidence>) throws -> [TextSearchExternalHit] {
            struct Key: Hashable { let field: SearchField; let index: Int; let range: SearchTextRange }
            var grouped: [Key: Set<SearchTextOperand>] = [:]
            for item in evidence {
                if case .external(let field, let index) = item.origin {
                    grouped[.init(field: field, index: index, range: item.range), default: []].insert(item.operand)
                }
            }
            guard grouped.count <= options.maximumHits else { throw TextSearchError.hitLimit }
            return grouped.keys.sorted {
                if $0.field != $1.field { return $0.field.rawValue < $1.field.rawValue }
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location
            }.map { key in
                .init(field: key.field, valueIndex: key.index, value: fields!.externalValues![key.field]![key.index], range: key.range,
                    operands: grouped[key]!.sorted { $0.sourceRange.location < $1.sourceRange.location })
            }
        }

        func makeHits(_ evidence: Set<Evidence>) throws -> [TextSearchHit] {
            let grouped = Dictionary(grouping: evidence.filter { $0.origin == .reader }, by: \.range)
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
