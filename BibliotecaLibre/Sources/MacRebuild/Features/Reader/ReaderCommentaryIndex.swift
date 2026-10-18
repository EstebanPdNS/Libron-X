import Foundation
import LibronixCore

/// Read-only coverage for explicitly linked study notes. Ordinary references,
/// footnotes and later citations in a note cannot become commentary owners.
struct ReaderCommentaryIndex {
    struct Heading: Decodable {
        var text: String
        var inlineLinks: [LegacyInlineLink]
    }
    static func build(anchors: [LegacyReferenceAnchor], textLength: Int,
        links: [LegacyInlineLink], heading: (Int) -> Heading?) -> [String: Int] {
        let index = ReaderBibleIndex(anchors: anchors, textLength: textLength)
        let addresses = index.references.compactMap(LegacyPassageQuery.sourceReference)
        let owners: [(LegacyPassageQuery, Int)] = links.compactMap { link in
            guard link.role == .studyCommentary, let ordinal = link.sectionOrdinal,
                  let owner = index.reference(at: link.range.location).flatMap(LegacyPassageQuery.sourceReference) else { return nil }
            return (owner, ordinal)
        }
        return build(owners: owners, addresses: addresses, heading: heading)
    }
    static func build(owners: [(LegacyPassageQuery, Int)], addresses: [LegacyPassageQuery],
        heading: (Int) -> Heading?) -> [String: Int] {
        var exact: [String: Int] = [:], ranges: [(BibleCopyPassage, Int)] = []
        for (owner, ordinal) in owners {
            if exact[owner.normalizedKey] == nil { exact[owner.normalizedKey] = ordinal }
            guard let note = heading(ordinal) else { continue }
            if note.inlineLinks.first?.range.location != 0, let passage = ReaderStudyNoteLinks.headingPassage(note.text, owner: owner) {
                ranges.append((passage, ordinal)); continue
            }
            guard let first = note.inlineLinks.first,
                  first.range.location == 0, first.range.length == first.label.utf16.count,
                  (note.text as NSString).length >= first.range.length,
                  (note.text as NSString).substring(with: first.range) == first.label,
                  case let .bible(destination) = first.target,
                  destination.passage.start == BibleCopyAddress(owner) else { continue }
            // Imported EPUB headings retain the full printed range while their
            // backlink may identify only its first verse. Extend only a heading
            // whose start agrees with BOTH verified source links.
            let printed = try? BibleCopyPassage.parse("\(owner.book) \(first.label)")
            let passage = printed.flatMap { $0.start == destination.passage.start && !$0.wholeChapter ? $0 : nil }
                ?? destination.passage
            guard !passage.wholeChapter, passage.start.bookKey == passage.end.bookKey else { continue }
            ranges.append((passage, ordinal))
        }
        var result = exact
        for address in addresses where result[address.normalizedKey] == nil {
            let containing = ranges.filter { passage, _ in
                address.sourceBookKey == passage.start.bookKey &&
                (address.chapter > passage.start.chapter || address.chapter == passage.start.chapter && address.verse >= passage.start.verse) &&
                (address.chapter < passage.end.chapter || address.chapter == passage.end.chapter && address.verse <= passage.end.verse)
            }
            // Prefer the latest explicit start when headings overlap; a verse's
            // own note always wins over a broader range.
            let match = containing.max { a, b in
                a.0.start.chapter == b.0.start.chapter ? a.0.start.verse < b.0.start.verse : a.0.start.chapter < b.0.start.chapter
            }
            if let match { result[address.normalizedKey] = match.1 }
        }
        return result
    }
}
