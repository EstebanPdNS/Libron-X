import Foundation

public struct BiblePassageVerse: Sendable, Equatable {
    public let reference: String
    public let key: String
    public let text: String
    public let sectionOrdinal: Int
    public let sourceRange: SearchTextRange
    public let sourceFingerprint: String
}

public struct BiblePassageEdition: Sendable {
    public let resource: LibraryResource
    public let verses: [BiblePassageVerse]
    public let sourceStamps: [LibrarySearchFileStamp]
    public let examinedArticles: Int
    public let complete: Bool
    public let warnings: [String]
    public let failure: String?
}

/// A source-backed report, independent of UI and storage. Sources are scanned
/// through the same checked projections as search. Missing means absent from a
/// completed scan; a failed/limited scan must never claim a verse is absent.
public actor BiblePassageReportService {
    private let provider: any LibrarySearchContentProvider
    public init(provider: any LibrarySearchContentProvider) { self.provider = provider }

    public func read(_ resource: LibraryResource, range: BibleSearchRange,
                     maximumArticles: Int = 100_000, maximumCharacters: Int = 8_000_000) async throws -> BiblePassageEdition {
        guard maximumArticles > 0, maximumCharacters > 0 else { throw TextComparisonError.limitExceeded }
        var examined = 0, warnings: [String] = []
        do {
            guard await provider.supports(resource) else { throw ReaderOutputError.unsupportedFormat }
            let prepared = try await provider.prepare(resource), predicate = range.bind(to: resource)
            warnings = prepared.warnings
            var verses: [BiblePassageVerse] = [], keys = Set<String>(), characters = 0
            for article in prepared.articles.prefix(maximumArticles) {
                try Task.checkCancellation()
                let decoded = try await provider.read(resource, article: article, prepared: prepared)
                examined += 1; warnings += decoded.warnings
                let observed = decoded.referenceAnchors.isEmpty ? decoded.bibleVerses
                    : try BibleVerseText.intervals(text: decoded.text, anchors: decoded.referenceAnchors)
                try BibleVerseText.validate(observed, in: decoded.text)
                try decoded.fieldDirectory?.validate(in: decoded.text)
                let source = decoded.text as NSString
                let fingerprint = LibrarySearchService.textFingerprint(decoded.text)
                for verse in observed where try predicate.contains(verse) {
                    guard keys.insert(verse.normalizedReference).inserted else { throw LibrarySearchError.invalidVerseDirectory }
                    let spans = decoded.fieldDirectory?.regions[.bibleText]?.compactMap { field -> SearchTextRange? in
                        let lo = max(field.location, verse.range.location), hi = min(field.upperBound, verse.range.upperBound)
                        return hi > lo ? .init(location: lo, length: hi - lo) : nil
                    } ?? [verse.range]
                    let text = spans.map { source.substring(with: $0.nsRange) }.joined()
                    characters += text.utf16.count
                    guard characters <= maximumCharacters else { throw TextComparisonError.limitExceeded }
                    verses.append(.init(reference: verse.reference, key: verse.normalizedReference, text: text,
                        sectionOrdinal: article.sectionOrdinal, sourceRange: verse.range, sourceFingerprint: fingerprint))
                }
            }
            try Task.checkCancellation(); try await provider.verifyUnchanged(resource, prepared: prepared)
            return .init(resource: resource, verses: verses, sourceStamps: prepared.sourceStamps, examinedArticles: examined,
                complete: examined == prepared.articles.count && warnings.isEmpty,
                warnings: Array(Set(warnings)).sorted(), failure: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A source change invalidates even earlier text from this edition.
            return .init(resource: resource, verses: [], sourceStamps: [], examinedArticles: examined,
                complete: false, warnings: Array(Set(warnings)).sorted(), failure: error.localizedDescription)
        }
    }
}

public enum BiblePassageReport {
    public static func references(in editions: [BiblePassageEdition], requested: String) -> [String] {
        var keys = Set(editions.flatMap { $0.verses.map(\.key) })
        // An explicit same-chapter interval names every requested address even
        // when none of the editions supplies it. No text or canon is invented.
        if let passage = try? BibleCopyPassage.parse(requested), !passage.wholeChapter,
           passage.start.bookKey == passage.end.bookKey, passage.start.chapter == passage.end.chapter,
           passage.end.verse - passage.start.verse <= 10_000 {
            for verse in passage.start.verse...passage.end.verse {
                keys.insert("\(passage.start.bookKey) \(passage.start.chapter):\(verse)")
            }
        }
        let order = Dictionary(uniqueKeysWithValues: LegacyPassageQuery.referenceBookOrder.enumerated().map { ($0.element, $0.offset) })
        return keys.sorted { a, b in
            guard let x = LegacyPassageQuery.parse(a), let y = LegacyPassageQuery.parse(b) else { return a < b }
            let xi = order[x.sourceBookKey] ?? Int.max, yi = order[y.sourceBookKey] ?? Int.max
            if xi != yi { return xi < yi }
            if x.sourceBookKey != y.sourceBookKey { return x.sourceBookKey < y.sourceBookKey }
            return (x.chapter, x.verse) < (y.chapter, y.verse)
        }
    }

    /// RFC 4180 cells, with spreadsheet formula interpretation disabled.
    public static func csv(editions: [BiblePassageEdition], requested: String) -> String {
        var rows = [["reference", "edition", "resource_id", "source_reference", "text", "status"]]
        let indexes = editions.map { Dictionary(uniqueKeysWithValues: $0.verses.map { ($0.key, $0) }) }
        for reference in references(in: editions, requested: requested) {
            for (index, edition) in editions.enumerated() {
                let verse = indexes[index][reference]
                rows.append([reference, edition.resource.title, edition.resource.legacyIdentifier ?? edition.resource.fileName,
                    verse?.reference ?? "", verse?.text ?? "", verse == nil ? edition.complete ? "missing" : "unverified" : "present"])
            }
        }
        return rows.map(CSVOutput.row).joined()
    }
}
