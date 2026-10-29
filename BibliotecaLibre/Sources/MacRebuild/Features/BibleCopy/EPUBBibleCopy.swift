import Foundation
import LibronixCore

/// Projects explicitly anchored Scripture, retaining inline emphasis and
/// resolving footnote references from the same checked EPUB archive.
@MainActor enum EPUBBibleCopy {
    static func prepare(_ resource: LibraryResource, passage: BibleCopyPassage, includeFootnotes: Bool) async throws -> BibleCopyDocument {
        let archive = try await EPUBReader.shared.prepare(resource.location), book = archive.book
        let worker = Task.detached { try EPUBBibleDirectory(book: book) }
        let directory = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        func bookNumber(_ address: BibleCopyAddress) throws -> Int {
            guard let index = ESwordResource.bookCodes.prefix(66).firstIndex(where: {
                LegacyPassageQuery.sourceReference($0 + " 1:1")?.sourceBookKey == address.bookKey
            }) else { throw BibleCopyError.invalidPassage }
            return index + 1
        }
        let firstBook = try bookNumber(passage.start), lastBook = try bookNumber(passage.end)
        let all = directory.entries
        guard let first = all.firstIndex(where: { $0.book == firstBook && $0.chapter == passage.start.chapter && $0.verse == passage.start.verse }) else {
            throw BibleCopyError.missingBoundary
        }
        let last: Int
        if passage.wholeChapter {
            guard let found = all.lastIndex(where: { $0.book == firstBook && $0.chapter == passage.start.chapter }) else { throw BibleCopyError.missingBoundary }
            last = found
        } else {
            guard let found = all.firstIndex(where: { $0.book == lastBook && $0.chapter == passage.end.chapter && $0.verse == passage.end.verse }) else { throw BibleCopyError.missingBoundary }
            last = found
        }
        guard last >= first else { throw BibleCopyError.reversedPassage }
        guard last - first < 10_000 else { throw BibleCopyError.limitExceeded }
        let selected = Array(all[first...last])
        for (previous, next) in zip(selected, selected.dropFirst()) {
            let consecutive = next.book == previous.book && next.chapter == previous.chapter && next.verse == previous.verse + 1 ||
                next.book == previous.book && next.chapter == previous.chapter + 1 && next.verse == 1 ||
                next.book == previous.book + 1 && next.chapter == 1 && next.verse == 1
            guard consecutive else { throw BibleCopyError.incompleteSource }
        }
        let projectionTask = Task.detached {
            let text = try EPUBBibleText.read(book: book, entries: selected, directory: directory)
            let notes = includeFootnotes ? try EPUBBibleText.footnotes(book: book, pieces: text.values.flatMap { $0 }) : [:]
            return (text, notes)
        }
        let (projection, resolvedNotes) = try await withTaskCancellationHandler { try await projectionTask.value } onCancel: { projectionTask.cancel() }
        var verses: [BibleCopyVerse] = [], notes: [BibleCopyFootnote] = [], sources: [ReaderOutputSource] = []
        var paragraphs: [BibleCopySourceParagraph] = []
        var group: Int?, groupFragments: [BibleCopyFragment] = [], groupMarks: [BibleCopySourceMark] = [], groupOffset = 0
        var total = 0
        for entry in selected {
            await Task.yield(); try Task.checkCancellation()
            guard let query = LegacyPassageQuery.sourceReference("\(ESwordResource.bookCodes[entry.book - 1]) \(entry.chapter):\(entry.verse)"),
                  let pieces = projection[entry.fragment] else { throw BibleCopyError.incompleteSource }
            let address = BibleCopyAddress(query), reference = query.displayReference
            var rawText = "", rawParagraph: Int?
            for piece in pieces {
                if let rawParagraph, rawParagraph != piece.paragraph { rawText += "\n" }
                rawText += piece.text; rawParagraph = piece.paragraph
            }
            total += rawText.utf16.count
            guard total <= 4_000_000 else { throw BibleCopyError.limitExceeded }
            let source = ReaderOutputSource(sectionOrdinal: entry.ordinal, decodedTextSHA256: LibrarySearchService.textFingerprint(rawText),
                selectedRange: .init(location: 0, length: rawText.utf16.count), verseReference: reference)
            var fragments: [BibleCopyFragment] = [], offset = 0, marked = false, verseParagraph: Int?
            for piece in pieces {
                if let verseParagraph, verseParagraph != piece.paragraph {
                    fragments.append(.init(text: "\n", style: nil, sourceRange: .init(location: offset, length: 1), footnote: nil, isBibleText: true, isVerseNumber: false))
                    offset += 1
                }
                verseParagraph = piece.paragraph
                if group != piece.paragraph {
                    if group != nil { paragraphs.append(.init(style: nil, fragments: groupFragments, marks: groupMarks)) }
                    group = piece.paragraph; groupFragments = []; groupMarks = []; groupOffset = 0
                }
                if !marked { groupMarks.append(.init(offset: groupOffset, address: address)); marked = true }
                var footnoteID: String?
                if piece.noteTarget != nil {
                    if !includeFootnotes { offset += piece.text.utf16.count; groupOffset += piece.text.utf16.count; continue }
                    guard let note = resolvedNotes[piece.noteKey] else { throw BibleCopyError.missingBoundary }
                    footnoteID = note.id
                    if !notes.contains(where: { $0.id == note.id }) {
                        let noteSource = ReaderOutputSource(sectionOrdinal: note.ordinal, decodedTextSHA256: LibrarySearchService.textFingerprint(note.text),
                            selectedRange: .init(location: 0, length: note.text.utf16.count), verseReference: reference)
                        notes.append(.init(id: note.id, marker: piece.text, text: note.text, source: noteSource))
                    }
                }
                let style = LegacyCharacterStyle.importedOutput(bold: piece.bold, italic: piece.italic, underline: piece.underline,
                    strikeout: piece.strikeout, superscript: false, subscriptText: false, color: nil, smallCaps: piece.smallCaps)
                let length = piece.text.utf16.count
                fragments.append(.init(text: piece.text, style: style, sourceRange: .init(location: offset, length: length), footnote: footnoteID, isBibleText: footnoteID == nil, isVerseNumber: false))
                groupFragments.append(.init(text: piece.text, style: style, sourceRange: .init(location: groupOffset, length: length), footnote: footnoteID, isBibleText: footnoteID == nil, isVerseNumber: false))
                offset += length; groupOffset += length
            }
            guard fragments.contains(where: { $0.isBibleText && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw BibleCopyError.incompleteSource }
            verses.append(.init(address: address, sourceReference: reference, source: source, paragraphKey: entry.fragment, paragraphStyle: nil, fragments: fragments))
            sources.append(source)
        }
        if group != nil { paragraphs.append(.init(style: nil, fragments: groupFragments, marks: groupMarks)) }
        try book.verifySource()
        let report = try BibliographyReportGenerator.generate(resources: [resource], scope: .init(kind: .selection, names: [], requestedCount: 1))
        return BibleCopyDocument(resourceID: resource.id, passage: passage, title: resource.title,
            abbreviation: resource.location.deletingPathExtension().lastPathComponent, verses: verses, footnotes: notes,
            citation: ResourceCitation.text(report.entries[0], style: .catalog), sources: sources,
            fullParagraphs: [], sourceLanguages: resource.languages, sourceParagraphs: paragraphs)
    }
}
