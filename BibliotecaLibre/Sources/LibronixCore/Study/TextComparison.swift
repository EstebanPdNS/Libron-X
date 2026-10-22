import Foundation

public struct TextComparisonOptions: Codable, Equatable, Sendable {
    public var caseSensitive = true
    public var accentSensitive = true
    public var punctuationSensitive = true
    public init() {}
}

public struct TextDifference: Equatable, Sendable {
    public enum Kind: String, Sendable { case addition, omission, substitution }
    public let kind: Kind
    public let base: SearchTextRange
    public let compared: SearchTextRange
}

public enum TextComparisonError: Error, LocalizedError, Sendable {
    case limitExceeded
    public var errorDescription: String? { "El texto supera el límite de comparación. Selecciona un pasaje más corto." }
}

/// Word/punctuation comparison. Every returned range addresses the unchanged
/// input's UTF-16 text at grapheme boundaries. Folding affects keys only.
/// Whitespace is presentation, so changes consisting only of spacing are ignored.
public enum TextComparison {
    private struct Token { let key: String; let range: SearchTextRange }
    public static func differences(base: String, compared: String,
                                   options: TextComparisonOptions = .init()) throws -> [TextDifference] {
        guard base.utf16.count <= 100_000, compared.utf16.count <= 100_000 else { throw TextComparisonError.limitExceeded }
        let a = try tokens(base, options: options), b = try tokens(compared, options: options)
        let columns = b.count + 1
        guard a.count + 1 <= 4_000_000 / columns else { throw TextComparisonError.limitExceeded }
        var lengths = [UInt32](repeating: 0, count: (a.count + 1) * columns)
        for i in a.indices.reversed() {
            try Task.checkCancellation()
            for j in b.indices.reversed() {
                lengths[i * columns + j] = a[i].key == b[j].key
                    ? 1 + lengths[(i + 1) * columns + j + 1]
                    : max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
            }
        }
        var matches: [(Int, Int)] = [], i = 0, j = 0
        while i < a.count, j < b.count {
            try Task.checkCancellation()
            if a[i].key == b[j].key { matches.append((i, j)); i += 1; j += 1 }
            else if lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] { i += 1 }
            else { j += 1 }
        }
        func span(_ tokens: [Token], _ lower: Int, _ upper: Int, _ end: Int) -> SearchTextRange {
            guard lower < upper else { return .init(location: lower < tokens.count ? tokens[lower].range.location : end, length: 0) }
            return .init(location: tokens[lower].range.location,
                         length: tokens[upper - 1].range.upperBound - tokens[lower].range.location)
        }
        var result: [TextDifference] = [], ai = 0, bi = 0
        for (nextA, nextB) in matches + [(a.count, b.count)] {
            if ai < nextA || bi < nextB {
                result.append(.init(kind: ai == nextA ? .addition : bi == nextB ? .omission : .substitution,
                    base: span(a, ai, nextA, base.utf16.count), compared: span(b, bi, nextB, compared.utf16.count)))
            }
            ai = nextA + 1; bi = nextB + 1
        }
        return result
    }

    private static func tokens(_ text: String, options: TextComparisonOptions) throws -> [Token] {
        var result: [Token] = [], wordStart: String.Index?
        var folding: String.CompareOptions = []
        if !options.caseSensitive { folding.insert(.caseInsensitive) }
        if !options.accentSensitive { folding.insert(.diacriticInsensitive) }
        func append(_ range: Range<String.Index>) {
            let key = String(text[range]).precomposedStringWithCanonicalMapping
                .folding(options: folding, locale: Locale(identifier: "en_US_POSIX"))
            guard !key.isEmpty else { return }
            let ns = NSRange(range, in: text)
            result.append(.init(key: key, range: .init(location: ns.location, length: ns.length)))
        }
        for index in text.indices {
            if result.count.isMultiple(of: 256) { try Task.checkCancellation() }
            let character = text[index]
            let isWord = character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }
            if isWord { if wordStart == nil { wordStart = index }; continue }
            if let start = wordStart { append(start..<index); wordStart = nil }
            let punctuation = character.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            if !character.isWhitespace && (options.punctuationSensitive || !punctuation) {
                append(index..<text.index(after: index))
            }
        }
        if let start = wordStart { append(start..<text.endIndex) }
        return result
    }
}
