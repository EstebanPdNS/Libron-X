import LibronixCore

/// Parse original reference labels once per committed article. Viewport reads
/// use a binary search; linked readers use an exact source-reference lookup.
/// No edition's character offsets are reused in a different resource.
struct ReaderBibleIndex {
    struct Entry { let offset: Int; let reference: String }
    let entries: [Entry]
    let offsets: [String: Int]
    let references: [String]
    init(anchors: [LegacyReferenceAnchor], textLength: Int? = nil) {
        var entries: [Entry] = [], offsets: [String: Int] = [:], references: [String] = []
        for anchor in anchors {
            guard anchor.characterOffset >= 0, textLength.map({ anchor.characterOffset < $0 }) ?? true else { continue }
            guard let raw = anchor.reference, let query = LegacyPassageQuery.sourceReference(raw) else { continue }
            entries.append(.init(offset: anchor.characterOffset, reference: query.displayReference))
            if offsets[query.normalizedKey] == nil {
                offsets[query.normalizedKey] = anchor.characterOffset
                references.append(query.displayReference)
            }
        }
        // Stable ties retain the original order when two anchors share a boundary.
        self.entries = entries.enumerated().sorted {
            $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset
        }.map(\.element)
        self.offsets = offsets; self.references = references
    }
    func reference(at offset: Int) -> String? {
        var lower = 0, upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].offset <= offset { lower = middle + 1 } else { upper = middle }
        }
        return entries.isEmpty ? nil : entries[max(0, lower - 1)].reference
    }
}
