import Foundation

/// One result per list entry, including duplicates, in the list's own order.
public struct StudyVerseListRow: Sendable {
    public enum State: Sendable, Equatable { case available, partial, missing, unverified, invalid }
    public let entryID: UUID
    public let reference: String
    public let verses: [BiblePassageVerse]
    public let state: State
}

public struct StudyVerseListReport: Sendable {
    public let documentID: UUID
    public let edition: BiblePassageEdition?
    public let rows: [StudyVerseListRow]
}

/// Reads each edition once, preserving the distinction between a missing verse,
/// an incomplete scan and an invalid list entry. Never converts versifications.
public actor StudyVerseListReportService {
    private let passage: BiblePassageReportService
    public init(provider: any LibrarySearchContentProvider) { passage = .init(provider: provider) }

    public func read(_ document: StudyDocument, resource: LibraryResource) async throws -> StudyVerseListReport {
        try document.validate()
        guard document.kind == .verseList else { throw BibleSearchRangeError.notReferenceList }
        var validDocument = document
        var ranges: [UUID: BibleSearchRange] = [:]
        for entry in document.verses {
            try Task.checkCancellation()
            do { ranges[entry.id] = try BibleSearchRange.parse(entry.reference) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        validDocument.verses = document.verses.filter { ranges[$0.id] != nil }
        guard !validDocument.verses.isEmpty else {
            return .init(documentID: document.id, edition: nil, rows: document.verses.map {
                .init(entryID: $0.id, reference: $0.reference, verses: [], state: .invalid)
            })
        }
        let range = try BibleSearchRange.referenceList(validDocument)
        let edition = try await passage.read(resource, range: range)
        struct IndexedVerse {
            let address: BibleReferenceAddress
            let verse: BiblePassageVerse
        }
        let indexed: [IndexedVerse] = try edition.verses.map { verse in
            guard let query = LegacyPassageQuery.parse(verse.key) else { throw LibrarySearchError.invalidVerseDirectory }
            return .init(address: .init(book: query.sourceBookKey, chapter: query.chapter, verse: query.verse), verse: verse)
        }.sorted { $0.address < $1.address }
        func lowerBound(_ address: BibleReferenceAddress) -> Int {
            var low = 0, high = indexed.count
            while low < high {
                let mid = low + (high - low) / 2
                if indexed[mid].address < address { low = mid + 1 } else { high = mid }
            }
            return low
        }
        var outputCharacters = 0
        let rows = try document.verses.map { entry -> StudyVerseListRow in
            try Task.checkCancellation()
            guard let entryRange = ranges[entry.id] else {
                return .init(entryID: entry.id, reference: entry.reference, verses: [], state: .invalid)
            }
            let predicate = entryRange.bind(to: resource)
            var found: [String: BiblePassageVerse] = [:]
            for span in entryRange.intervals.values.flatMap({ $0 }) {
                var position = lowerBound(span.lower)
                while position < indexed.count, indexed[position].address <= span.upper {
                    try Task.checkCancellation()
                    let verse = indexed[position].verse
                    let candidate = LibrarySearchBibleVerse(reference: verse.reference, normalizedReference: verse.key, range: verse.sourceRange)
                    if try predicate.contains(candidate) { found[verse.key] = verse }
                    position += 1
                }
            }
            let verses = found.values.sorted { a, b in
                guard let left = LegacyPassageQuery.parse(a.key), let right = LegacyPassageQuery.parse(b.key) else { return a.key < b.key }
                return BibleReferenceAddress(book: left.sourceBookKey, chapter: left.chapter, verse: left.verse) <
                    BibleReferenceAddress(book: right.sourceBookKey, chapter: right.chapter, verse: right.verse)
            }
            for verse in verses {
                guard verse.text.utf16.count <= 16_000_000 - outputCharacters else { throw BibleSearchRangeError.tooLarge }
                outputCharacters += verse.text.utf16.count
            }
            // An explicit edition that did not match this resource is not proof
            // that the reference is absent from the named edition.
            let hasExplicitEdition = entryRange.intervals.keys.contains { !$0.isEmpty }
            let state: StudyVerseListRow.State
            if verses.isEmpty { state = edition.complete && !hasExplicitEdition ? .missing : .unverified }
            else if !edition.complete { state = .unverified }
            else {
                let spans = entryRange.intervals.values.flatMap { $0 }
                var requested = Set<BibleReferenceAddress>()
                var bounded = !hasExplicitEdition || entryRange.intervals.count == 1
                for span in spans {
                    guard bounded, span.lower.book == span.upper.book, span.lower.chapter == span.upper.chapter,
                          span.upper.verse < 65535, span.upper.verse - span.lower.verse <= 10_000 else { bounded = false; break }
                    for number in span.lower.verse...span.upper.verse {
                        try Task.checkCancellation()
                        requested.insert(.init(book: span.lower.book, chapter: span.lower.chapter, verse: number))
                    }
                    if requested.count > 10_000 { bounded = false; break }
                }
                if bounded { state = verses.count < requested.count ? .partial : .available }
                // An open chapter/book means all observed verses in that scope.
                // Closed cross-chapter intervals cannot imply unknown chapter lengths.
                else if !hasExplicitEdition && spans.allSatisfy({ $0.upper.verse == 65535 }) { state = .available }
                else { state = .unverified }
            }
            return .init(entryID: entry.id, reference: entry.reference, verses: verses, state: state)
        }
        return .init(documentID: document.id, edition: edition, rows: rows)
    }
}
