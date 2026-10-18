import Foundation

/// Source-declared visible fields. A missing entry is unsupported/unknown;
/// an explicitly empty entry proves that this field has no visible content.
public enum SearchField: String, Codable, CaseIterable, Hashable, Sendable {
    case title, body, footnote, heading
    case bibleText = "bible"
    case quotation = "quote"
}

public struct SearchFieldDirectory: Codable, Hashable, Sendable {
    public let regions: [SearchField: [SearchTextRange]]
    /// Text declared outside the visible reader stream, e.g. an index title.
    /// Its offsets never become reader positions. Optional for old cache records.
    public let externalValues: [SearchField: [String]]?
    /// Explicit producer-owned units that connect fragments separated only by
    /// presentation markers. Without these, positional witnesses stay local.
    public let witnessRegions: [SearchField: [SearchTextRange]]?
    public init(regions: [SearchField: [SearchTextRange]], externalValues: [SearchField: [String]]? = nil,
                witnessRegions: [SearchField: [SearchTextRange]]? = nil) {
        self.regions = regions; self.externalValues = externalValues; self.witnessRegions = witnessRegions
    }
    public func supports(_ field: SearchField) -> Bool { regions[field] != nil || externalValues?[field] != nil }
    public func clipped(to range: SearchTextRange, in text: String) throws -> Self {
        try validate(in: text)
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location,
              boundary(range.location, source), boundary(range.upperBound, source) else { throw TextSearchError.invalidFieldDirectory }
        var result: [SearchField: [SearchTextRange]] = [:]
        for (field, spans) in regions {
            result[field] = spans.compactMap { span in
                let start = max(range.location, span.location), end = min(range.upperBound, span.upperBound)
                return end > start ? .init(location: start - range.location, length: end - start) : nil
            }
        }
        let witnesses = witnessRegions?.mapValues { spans in spans.compactMap { span -> SearchTextRange? in
            let start = max(range.location, span.location), end = min(range.upperBound, span.upperBound)
            return end > start ? .init(location: start - range.location, length: end - start) : nil
        } }
        let projection = Self(regions: result, externalValues: externalValues, witnessRegions: witnesses)
        try projection.validate(in: source.substring(with: range.nsRange))
        return projection
    }

    /// Validate before matching. Never infer semantic roles from a style, a
    /// title-shaped string, a native frame flag or a guessed file name.
    public func validate(in text: String) throws {
        let source = text as NSString
        guard regions.values.reduce(0, { $0 + $1.count }) + (witnessRegions?.values.reduce(0, { $0 + $1.count }) ?? 0) <= 100_000 else { throw TextSearchError.invalidFieldDirectory }
        let values = externalValues?.values.flatMap { $0 } ?? []
        guard values.count <= 256, values.reduce(0, { $0 + $1.utf16.count }) <= 65_536,
              values.allSatisfy({ $0.utf16.count <= 8192 && !$0.contains("\0") }) else { throw TextSearchError.invalidFieldDirectory }
        for ranges in Array(regions.values) + Array(witnessRegions?.values ?? [:].values) {
            var end = 0
            for range in ranges {
                try Task.checkCancellation()
                guard range.location >= end, range.length > 0, range.location <= source.length,
                      range.length <= source.length - range.location,
                      boundary(range.location, source), boundary(range.upperBound, source) else { throw TextSearchError.invalidFieldDirectory }
                end = range.upperBound
            }
        }
        for (field, units) in witnessRegions ?? [:] {
            guard let parts = regions[field], parts.allSatisfy({ Self.contains($0, ranges: units) }) else { throw TextSearchError.invalidFieldDirectory }
        }
    }
    private func boundary(_ offset: Int, _ source: NSString) -> Bool {
        offset == source.length || source.rangeOfComposedCharacterSequence(at: offset).location == offset
    }
    /// Complete containment keeps a phrase or a positional witness from
    /// bridging disjoint field fragments. Different fields may overlap.
    public func contains(_ range: SearchTextRange, in field: SearchField) -> Bool {
        Self.contains(range, ranges: regions[field] ?? [])
    }
    public func containsWitness(_ range: SearchTextRange, in field: SearchField) -> Bool {
        Self.contains(range, ranges: witnessRegions?[field] ?? regions[field] ?? [])
    }
    private static func contains(_ range: SearchTextRange, ranges: [SearchTextRange]) -> Bool {
        guard range.location >= 0, range.length > 0, range.length <= Int.max - range.location else { return false }
        var low = 0, high = ranges.count
        while low < high {
            let mid = low + (high - low) / 2
            if ranges[mid].location <= range.location { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return false }
        let owner = ranges[low - 1]
        guard owner.location >= 0, owner.length > 0, owner.length <= Int.max - owner.location else { return false }
        return range.upperBound <= owner.upperBound
    }
}
