import Foundation

public enum ScriptureMemorySource {
    /// Compatibility entry point for an independently supplied reference label.
    public static func card(reference: String, document: BibleCopyDocument) throws -> ScriptureMemoryCard {
        try makeCard(reference: reference, document: document, edition: nil)
    }
    /// The edition link and reference derive from the checked source request,
    /// not from a separately supplied label or inferred book name.
    public static func card(document: BibleCopyDocument, resource: LibraryResource) throws -> ScriptureMemoryCard {
        guard resource.id == document.resourceID, resource.format == .legacyLSF else { throw LegacyLocatorError.resourceMismatch }
        return try makeCard(reference: document.passage.original.trimmingCharacters(in: .whitespacesAndNewlines),
            document: document, edition: StudyBibleEdition(resource))
    }
    private static func makeCard(reference: String, document: BibleCopyDocument, edition: StudyBibleEdition?) throws -> ScriptureMemoryCard {
        try Task.checkCancellation()
        guard !document.verses.isEmpty else { throw PersonalStateError.invalid("La fuente no contiene el pasaje solicitado.") }
        var lines: [String] = [], bytes = 0
        for verse in document.verses {
            try Task.checkCancellation()
            let line = verse.fragments.filter { $0.isBibleText && !$0.isVerseNumber && $0.footnote == nil }
                .map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { throw PersonalStateError.invalid("La fuente no contiene el pasaje solicitado.") }
            let additional = line.utf8.count + (lines.isEmpty ? 0 : 1)
            guard additional <= 64_000 - bytes else {
                throw PersonalStateError.invalid("El pasaje supera los 64.000 bytes del ejercicio. Elige un intervalo más corto.")
            }
            bytes += additional; lines.append(line)
        }
        let card = ScriptureMemoryCard(reference: reference, passage: lines.joined(separator: "\n"), source: document.title, sourceEdition: edition)
        try card.validate(); try Task.checkCancellation()
        return card
    }
}

public extension ScriptureMemoryCard {
    /// The source identity belongs to the exact extracted material. Restoring
    /// that material retains it; editing the transcription detaches the link.
    func edited(reference: String, passage: String, source: String, loadedSource: ScriptureMemoryCard?) throws -> Self {
        var next = self
        next.reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        next.passage = passage; next.source = source
        if let loadedSource, loadedSource.reference == next.reference,
           loadedSource.passage == passage, loadedSource.source == source {
            next.sourceEdition = loadedSource.sourceEdition
        } else { next.sourceEdition = nil }
        if self.reference != next.reference || self.passage != passage || self.source != source || self.sourceEdition != next.sourceEdition {
            next.attempts = 0; next.correct = 0; next.lastPracticed = nil
        }
        try next.validate()
        return next
    }
}
