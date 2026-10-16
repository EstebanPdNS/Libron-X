import Foundation

/// An interval named by a decoded source anchor, within one physical article.
/// This does not infer a canon or convert the resource's versification. The next
/// distinct source verse (or article end) defines its conservative text boundary.
public struct LibrarySearchBibleVerse: Hashable, Sendable {
    public let reference: String
    public let normalizedReference: String
    public let range: SearchTextRange

    public init(reference: String, normalizedReference: String, range: SearchTextRange) {
        self.reference = reference; self.normalizedReference = normalizedReference; self.range = range
    }
}

enum BibleVerseText {
    static func intervals(text: String, anchors: [LegacyReferenceAnchor]) throws -> [LibrarySearchBibleVerse] {
        // The observed Bible anchors in the reference resources use datatype 2.
        // Non-Bible labels and other datatypes remain outside this subset.
        let length = text.utf16.count
        var observed: [(reference: String, key: String, start: Int)] = []
        var previousSourceStart = 0
        var keys = Set<String>()
        for anchor in anchors where anchor.dataTypeCode == 2 {
            try Task.checkCancellation()
            guard let sourceReference = anchor.reference,
                  let reference = LegacyPassageQuery.parse(sourceReference) else { continue }
            let start = anchor.characterOffset
            guard start >= previousSourceStart, start <= length,
                  isBoundary(start, in: text) else {
                throw LibrarySearchError.invalidVerseDirectory
            }
            previousSourceStart = start
            if let previous = observed.last {
                guard start >= previous.start else { throw LibrarySearchError.invalidVerseDirectory }
                if reference.normalizedKey == previous.key { continue }
                guard start > previous.start else { throw LibrarySearchError.invalidVerseDirectory }
            }
            guard keys.insert(reference.normalizedKey).inserted else { throw LibrarySearchError.invalidVerseDirectory }
            observed.append((sourceReference, reference.normalizedKey, start))
        }
        return try observed.indices.map { index in
            let item = observed[index]
            let end = index + 1 < observed.count ? observed[index + 1].start : length
            let range = SearchTextRange(location: item.start, length: end - item.start)
            guard range.length > 0, isBoundary(end, in: text) else {
                throw LibrarySearchError.invalidVerseDirectory
            }
            return .init(reference: item.reference, normalizedReference: item.key, range: range)
        }
    }

    static func validate(_ intervals: [LibrarySearchBibleVerse], in text: String) throws {
        var end = 0
        var keys = Set<String>()
        let length = text.utf16.count
        for interval in intervals {
            try Task.checkCancellation()
            guard interval.range.location >= end, interval.range.length > 0,
                  interval.range.location <= length,
                  interval.range.length <= length - interval.range.location,
                  isBoundary(interval.range.location, in: text), isBoundary(interval.range.upperBound, in: text),
                  LegacyPassageQuery.parse(interval.reference)?.normalizedKey == interval.normalizedReference,
                  keys.insert(interval.normalizedReference).inserted else {
                throw LibrarySearchError.invalidVerseDirectory
            }
            end = interval.range.upperBound
        }
    }

    private static func isBoundary(_ offset: Int, in text: String) -> Bool {
        let source = text as NSString
        guard offset >= 0, offset <= source.length else { return false }
        if offset == source.length { return true }
        // Range(NSRange, in: String) alone can accept a position inside a UTF-16
        // surrogate pair. Never split that scalar or a composed character.
        return source.rangeOfComposedCharacterSequence(at: offset).location == offset
    }
}
