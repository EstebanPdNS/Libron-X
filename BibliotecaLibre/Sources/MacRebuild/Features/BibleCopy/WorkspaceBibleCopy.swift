import Foundation
import LibronixCore

/// Prepare passages through the appropriate checked source without changing
/// the identity of a Bible contained inside an LLS package.
@MainActor enum WorkspaceBibleCopy {
    static func prepare(_ resource: LibraryResource, passage: BibleCopyPassage, includeFootnotes: Bool) async throws -> BibleCopyDocument {
        let abbreviation = resource.location.deletingPathExtension().lastPathComponent
        if resource.format == .epub {
            return try await EPUBBibleCopy.prepare(resource, passage: passage, includeFootnotes: includeFootnotes)
        }
        if resource.format == .eSwordSQLite {
            let worker = Task.detached { try ESwordResource.biblePassage(resource, passage: passage) }
            let selection = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            return try await ESwordBibleCopy.prepare(selection, abbreviation: abbreviation)
        }
        if resource.format == .libronixLLS {
            let stamp = try LibrarySearchFileStamp.capture(resource.location)
            let inner = try await LibronixBookService.shared.prepare(resource)
            let document = try await BibleCopyService().prepare(inner, passage: passage, abbreviation: abbreviation, includeFootnotes: includeFootnotes, allowSerializedBibleAnchors: true)
            guard document.hasVerseText else { throw BibleCopyError.missingBoundary }
            try LibrarySearchFileStamp.verify([stamp])
            let report = try BibliographyReportGenerator.generate(resources: [resource], scope: .init(kind: .selection, names: [], requestedCount: 1))
            return BibleCopyDocument(resourceID: resource.id, passage: passage, title: resource.title, abbreviation: abbreviation,
                verses: document.verses, footnotes: document.footnotes, citation: ResourceCitation.text(report.entries[0], style: .catalog),
                typography: document.typography, sources: document.sources, fullParagraphs: document.fullParagraphs,
                sourceLanguages: document.sourceLanguages, sourceParagraphs: document.sourceParagraphs)
        }
        return try await BibleCopyService().prepare(resource, passage: passage, abbreviation: abbreviation, includeFootnotes: includeFootnotes)
    }
}
