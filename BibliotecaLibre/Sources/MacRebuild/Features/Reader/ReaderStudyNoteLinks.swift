import Foundation
import LibronixCore

/// Original books encode verse annotations as superscript marker runs pointing
/// to real sections. Preserve those verified links and normalize their role in
/// memory; ordinary word links, bullets and book navigation are not notes.
enum ReaderStudyNoteLinks {
    static func classify(_ links: [LegacyInlineLink], anchors: [LegacyReferenceAnchor],
        runs: [LegacyTextRun], typography: LegacyTypography?) -> [LegacyInlineLink] {
        guard let typography, anchors.contains(where: { $0.reference.flatMap(LegacyPassageQuery.sourceReference) != nil }) else { return links }
        let superscripts = runs.filter { typography.characterStyle($0.styleIdentifier)?.isSuperscript == true }
        guard !superscripts.isEmpty else { return links }
        return links.map { original in
            guard original.role == nil, original.sectionOrdinal != nil else { return original }
            let label = original.label.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0.properties.generalCategory != .format }
            let marker = String(String.UnicodeScalarView(label))
            let isMarker = (1...3).contains(label.count) && label.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) || ["*", "†", "‡", "§", "¶", "※", "⁎"].contains(marker)
            guard isMarker,
                  superscripts.contains(where: { NSLocationInRange(original.range.location, .init(location: $0.characterOffset, length: $0.text.utf16.count)) }) else { return original }
            var result = original; result.role = .studyCommentary; return result
        }
    }
    /// Only an initial, printed note address extends coverage. Later citations
    /// remain links and cannot take ownership of unrelated verses.
    static func headingPassage(_ text: String, owner: LegacyPassageQuery) -> BibleCopyPassage? {
        let pattern = #"^[\s\p{Cf}]*(?:[\p{L}\d]{1,3}[\s\p{Cf}]+)?(\d+[.:]\d+(?:[–—-]\d+(?:[.:]\d+)?)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: .init(location: 0, length: min(text.utf16.count, 128))),
              let range = Range(match.range(at: 1), in: text),
              let passage = try? BibleCopyPassage.parse(owner.book + " " + text[range].replacingOccurrences(of: ".", with: ":")),
              passage.start.bookKey == owner.sourceBookKey,
              (passage.start.chapter < owner.chapter || passage.start.chapter == owner.chapter && passage.start.verse <= owner.verse),
              (passage.end.chapter > owner.chapter || passage.end.chapter == owner.chapter && passage.end.verse >= owner.verse) else { return nil }
        return passage
    }
}
