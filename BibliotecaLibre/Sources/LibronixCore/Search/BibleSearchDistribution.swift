import Foundation

public enum BibleSearchDistributionGrouping: String, CaseIterable, Sendable {
    case book, chapter, ranges
}

public enum BibleSearchDistributionError: Error, LocalizedError, Equatable, Sendable {
    case requiresVerseResults, invalidResults, invalidRanges
    public var errorDescription: String? {
        switch self {
        case .requiresVerseResults: "La distribución bíblica requiere una búsqueda por versículo."
        case .invalidResults: "Los resultados no conservan referencias bíblicas e identidades válidas."
        case .invalidRanges: "Escribe entre uno y veinte rangos, uno por línea, sin duplicados."
        }
    }
}

public struct BibleSearchDistributionGroup: Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let resourceID: String
        public let key: String
    }
    public let id: ID
    public let title: String
    /// Original report order and source-bound identities, without synthesizing hits.
    public let results: [LibrarySearchResult]
    public var observedOccurrences: Int { results.reduce(0) { $0 + $1.hitCount } }
    public var retainedOccurrences: Int { results.reduce(0) { $0 + $1.hits.count + $1.externalHits.count } }
}

/// Counts retained report results separately for each physical edition. A verse
/// result is required: the first reference of an article cannot locate all its
/// matches. Overlapping custom ranges are independent, never additive totals.
public struct BibleSearchDistribution: Sendable {
    public let groups: [BibleSearchDistributionGroup]
    public let complete: Bool
    public let grouping: BibleSearchDistributionGrouping

    public static func build(report: LibrarySearchReport, resources: [LibraryResource],
                             grouping: BibleSearchDistributionGrouping, ranges: [String] = [],
                             scopeComplete: Bool = true) throws -> Self {
        guard report.unit == .bibleVerse else { throw BibleSearchDistributionError.requiresVerseResults }
        guard report.results.count <= 10_000,
              Set(report.results.map(\.id)).count == report.results.count,
              Set(resources.map(\.id)).count == resources.count else { throw BibleSearchDistributionError.invalidResults }
        let sources = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        let resourceOrder = Dictionary(uniqueKeysWithValues: resources.enumerated().map { ($0.element.id, $0.offset) })
        let names = ranges.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if grouping == .ranges {
            guard (1...20).contains(names.count), Set(names).count == names.count else { throw BibleSearchDistributionError.invalidRanges }
        }
        let compiled = grouping == .ranges ? try names.map(BibleSearchRange.parse) : []
        let bookOrder = Dictionary(uniqueKeysWithValues: LegacyPassageQuery.referenceBookOrder.enumerated().map { ($0.element, $0.offset) })
        struct Bucket {
            let id: BibleSearchDistributionGroup.ID
            let title: String
            let order: Int
            let chapter: Int
            var results: [LibrarySearchResult]
        }
        var buckets: [BibleSearchDistributionGroup.ID: Bucket] = [:]
        if grouping == .ranges {
            for resource in resources {
                for (index, title) in names.enumerated() {
                    let id = BibleSearchDistributionGroup.ID(resourceID: resource.id, key: String(index))
                    buckets[id] = .init(id: id, title: title, order: index, chapter: 0, results: [])
                }
            }
        }
        for result in report.results {
            try Task.checkCancellation()
            guard let resource = sources[result.resourceID], let reference = result.bibleReference,
                  let address = LegacyPassageQuery.parse(reference), address.chapter > 0, address.verse > 0,
                  let position = bookOrder[address.sourceBookKey], let extent = result.verseRange,
                  extent.location >= 0, extent.length > 0, extent.length <= Int.max - extent.location,
                  result.hitCount <= 1_000_000, result.hitCount >= result.hits.count + result.externalHits.count,
                  result.hits.allSatisfy({ $0.range.location >= extent.location && $0.range.length > 0 &&
                      $0.range.location <= extent.upperBound && $0.range.length <= extent.upperBound - $0.range.location }) else {
                throw BibleSearchDistributionError.invalidResults
            }
            func append(key: String, title: String, order: Int, chapter: Int = 0) {
                let id = BibleSearchDistributionGroup.ID(resourceID: result.resourceID, key: key)
                if buckets[id] == nil { buckets[id] = .init(id: id, title: title, order: order, chapter: chapter, results: []) }
                buckets[id]?.results.append(result)
            }
            switch grouping {
            case .book: append(key: address.sourceBookKey, title: address.sourceBookKey, order: position)
            case .chapter:
                let key = address.sourceBookKey + " " + String(address.chapter)
                append(key: key, title: key, order: position, chapter: address.chapter)
            case .ranges:
                let sourceReference = LegacyPassageQuery.parse(result.articleTitle)?.normalizedKey == address.normalizedKey ? result.articleTitle : reference
                let verse = LibrarySearchBibleVerse(reference: sourceReference, normalizedReference: address.normalizedKey, range: extent)
                for (index, range) in compiled.enumerated() where try range.bind(to: resource).contains(verse) {
                    append(key: String(index), title: names[index], order: index)
                }
            }
        }
        let groups = buckets.values.sorted {
            let left = resourceOrder[$0.id.resourceID] ?? Int.max, right = resourceOrder[$1.id.resourceID] ?? Int.max
            if left != right { return left < right }
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.chapter != $1.chapter { return $0.chapter < $1.chapter }
            return $0.id.key < $1.id.key
        }.map { BibleSearchDistributionGroup(id: $0.id, title: $0.title, results: $0.results) }
        return .init(groups: groups, complete: scopeComplete && report.coverageComplete && report.runState == .finished, grouping: grouping)
    }
}
