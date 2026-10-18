import Foundation

/// An interval named by a decoded source anchor, within one physical article.
/// This does not infer a canon or convert the resource's versification. The next
/// distinct source verse (or article end) defines its conservative text boundary.
public struct LibrarySearchBibleVerse: Hashable, Sendable, Codable {
    public let reference: String
    public let normalizedReference: String
    public let range: SearchTextRange

    public init(reference: String, normalizedReference: String, range: SearchTextRange) {
        self.reference = reference; self.normalizedReference = normalizedReference; self.range = range
    }
}

enum BibleVerseText {
    static func intervals(text: String, anchors: [LegacyReferenceAnchor]) throws -> [LibrarySearchBibleVerse] {
        // LSF textual Bible anchors use datatype 2. Observed LLS 0x52 anchors
        // use datatype 16 with an explicit serialized Bible scheme. Keep their
        // original datatype; ordinary type-16 labels must never become verses.
        let length = text.utf16.count
        var observed: [(reference: String, key: String, start: Int)] = []
        var previousSourceStart = 0
        var keys = Set<String>()
        for anchor in anchors {
            try Task.checkCancellation()
            guard let sourceReference = anchor.reference,
                  anchor.dataTypeCode == 2 || (anchor.dataTypeCode == 16 && serializedBibleScheme(sourceReference)),
                  let reference = LegacyPassageQuery.parse(sourceReference) else { continue }
            let start = anchor.characterOffset
            guard start >= previousSourceStart, start <= length,
                  isBoundary(start, in: text) else {
                throw LibrarySearchError.invalidVerseDirectory
            }
            previousSourceStart = start
            if let previous = observed.last {
                guard start >= previous.start else { throw LibrarySearchError.invalidVerseDirectory }
                if reference.normalizedKey == previous.key {
                    // Repeated markers may be aliases of one source verse.
                    // Distinct explicit editions cannot be merged into a single
                    // interval and attributed to the first edition's label.
                    guard edition(sourceReference) == edition(previous.reference) else { throw LibrarySearchError.invalidVerseDirectory }
                    continue
                }
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

    private static func serializedBibleScheme(_ reference: String) -> Bool {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (value.hasPrefix("bible.") || value.hasPrefix("bible+")) && LegacyPassageQuery.sourceReference(value) != nil
    }
    private static func edition(_ reference: String) -> String? {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("bible+"), let scheme = value.split(separator: ".").first else { return nil }
        return String(scheme.dropFirst(6))
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
