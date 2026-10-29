import Foundation

public enum ScriptureMemorySource {
    /// Use only source-identified verse bodies, never generated labels or
    /// fallback citations. The service verifies the requested boundaries.
    public static func card(reference: String, document: BibleCopyDocument) throws -> ScriptureMemoryCard {
        guard !document.verses.isEmpty else {
            throw PersonalStateError.invalid("La fuente no contiene el pasaje solicitado.")
        }
        let lines = document.verses.map { verse in
            verse.fragments.filter { $0.isBibleText && !$0.isVerseNumber && $0.footnote == nil }
                .map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.allSatisfy({ !$0.isEmpty }) else {
            throw PersonalStateError.invalid("La fuente no contiene el pasaje solicitado.")
        }
        let card = ScriptureMemoryCard(reference: reference, passage: lines.joined(separator: "\n"), source: document.title)
        try card.validate()
        return card
    }
}
