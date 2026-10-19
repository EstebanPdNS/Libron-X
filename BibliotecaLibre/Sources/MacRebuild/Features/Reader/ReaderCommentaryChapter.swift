import AppKit
import Foundation
import LibronixCore

extension LibronNativeReader {
    private struct ChapterMetadata: Decodable {
        struct Content: Decodable { var anchors: [LegacyReferenceAnchor]; var runs: [LegacyTextRun] }
        var text: String
        var content: Content?
        var inlineLinks: [LegacyInlineLink]
        var typographyKey: String?
    }
    private func commentaryReferences(_ db: LibronNativeDatabase, url: URL) throws -> [String] {
        if let saved = commentaryBookChapters[url] { return saved }
        let references = try db.chapterReferences()
        if commentaryBookChapters.count >= 8 { commentaryBookChapters.removeAll() }
        commentaryBookChapters[url] = references
        return references
    }
    /// Cache a book's explicit ownership once. Cross-chapter headings can then
    /// follow correctly even when the reader opens directly in the later chapter.
    func commentaryIndex(_ resource: LibraryResource, section: LibronNativeSection,
        db: LibronNativeDatabase, force: Bool = false, bookKey: String? = nil) throws -> [String: Int] {
        guard let url = Self.location(resource),
              force || commentaryIndexes[url] != nil || section.inlineLinks.contains(where: { $0.role == .studyCommentary }),
              let first = section.content?.anchors.lazy.compactMap({ $0.reference.flatMap(LegacyPassageQuery.sourceReference) }).first(where: { bookKey == nil || $0.sourceBookKey == bookKey }) else { return [:] }
        if let saved = commentaryIndexes[url]?[first.sourceBookKey] { return saved }
        guard force || section.inlineLinks.contains(where: { $0.role == .studyCommentary }) else { return [:] }
        var owners: [(LegacyPassageQuery, Int)] = [], addresses: [LegacyPassageQuery] = []
        var seen: Set<Int> = []
        for reference in try commentaryReferences(db, url: url) {
            try Task.checkCancellation()
            guard LegacyPassageQuery.sourceReference(reference)?.sourceBookKey == first.sourceBookKey else { continue }
            for ordinal in try db.chapterSectionOrdinals(reference) where seen.insert(ordinal).inserted {
                guard let data = try db.get("section/\(ordinal)") else { continue }
                let chapter = try JSONDecoder().decode(ChapterMetadata.self, from: data)
                let index = ReaderBibleIndex(anchors: chapter.content?.anchors ?? [], textLength: chapter.text.utf16.count)
                addresses += index.references.compactMap(LegacyPassageQuery.sourceReference).filter { $0.sourceBookKey == first.sourceBookKey }
                let links = ReaderStudyNoteLinks.classify(chapter.inlineLinks, anchors: chapter.content?.anchors ?? [],
                    runs: chapter.content?.runs ?? [], typography: try nativeTypography(chapter.typographyKey, db: db, url: url))
                for link in links where link.role == .studyCommentary {
                    if let ordinal = link.sectionOrdinal,
                       let owner = index.reference(at: link.range.location).flatMap(LegacyPassageQuery.sourceReference), owner.sourceBookKey == first.sourceBookKey {
                        owners.append((owner, ordinal))
                    }
                }
            }
        }
        let result = ReaderCommentaryIndex.build(owners: owners, addresses: addresses) { ordinal in
            guard let data = try? db.get("section/\(ordinal)") else { return nil }
            return try? JSONDecoder().decode(ReaderCommentaryIndex.Heading.self, from: data)
        }
        if commentaryIndexes.values.reduce(0, { $0 + $1.count }) >= 8 { commentaryIndexes.removeAll() }
        commentaryIndexes[url, default: [:]][first.sourceBookKey] = result
        return result
    }
    func readCommentaryChapter(_ resource: LibraryResource, _ requested: ReaderDestination) async throws -> ReaderPage {
        if LibronMetadata.deriving(resource).resourceType == "Comentario bíblico" {
            return try await readStandaloneCommentary(resource, requested)
        }
        guard let chapter = requested.commentaryChapter.flatMap(LegacyPassageQuery.sourceReference),
              let url = Self.location(resource) else { throw RebuildError.referenceNotFound }
        let key = "\(chapter.sourceBookKey) \(chapter.chapter):1"
        var result: ReaderPage
        if let saved = commentaryChapters[url]?[key] { result = saved }
        else {
            var source = try await read(resource, .init(ordinal: requested.ordinal, reference: key))
            let db = try LibronNativeDatabase(url)
            if source.commentaryOrdinals.isEmpty, let data = try db.get("section/\(source.destination.ordinal)") {
                source.commentaryOrdinals = try commentaryIndex(resource,
                    section: JSONDecoder().decode(LibronNativeSection.self, from: data), db: db, force: true, bookKey: chapter.sourceBookKey)
            }
            let chapters = try commentaryReferences(db, url: url)
            let chapterIndex = chapters.firstIndex { LegacyPassageQuery.sourceReference($0)?.normalizedKey == key }
            var fragments: [ReaderPage] = []
            for ordinal in try db.chapterSectionOrdinals(key) {
                fragments.append(ordinal == source.destination.ordinal ? source : try await read(resource, .init(ordinal: ordinal)))
            }
            let references = fragments.flatMap { $0.content?.anchors.compactMap { $0.reference.flatMap(LegacyPassageQuery.sourceReference) } ?? [] }
                .filter { $0.sourceBookKey == chapter.sourceBookKey && $0.chapter == chapter.chapter }
                .sorted { $0.verse < $1.verse }
            let linked = fragments.flatMap { fragment -> [Int] in
                let index = ReaderBibleIndex(anchors: fragment.content?.anchors ?? [], textLength: fragment.text.utf16.count)
                return fragment.inlineLinks.compactMap { link in
                    guard link.role == .studyCommentary,
                          let owner = index.reference(at: link.range.location).flatMap(LegacyPassageQuery.sourceReference),
                          owner.sourceBookKey == chapter.sourceBookKey, owner.chapter == chapter.chapter else { return nil }
                    return link.sectionOrdinal
                }
            }
            let ordinals = Set(linked + references.compactMap { source.commentaryOrdinals[$0.normalizedKey] }).sorted()
            let combined = NSMutableAttributedString(string: "")
            var links: [LegacyInlineLink] = [], graphics: [LegacyGraphicAsset] = [], offsets: [Int: Int] = [:]
            for ordinal in ordinals {
                try Task.checkCancellation()
                let note = try await read(resource, .init(ordinal: ordinal))
                let offset = combined.length; offsets[ordinal] = offset
                let rtf: Data?
                if let original = note.content?.richTextRTF { rtf = original }
                else {
                    rtf = try await MainActor.run {
                        let rendered = ReaderTypography.render(text: note.text, content: note.content,
                            typography: note.typography, usesChosenFont: false).text
                        return try rendered.data(from: .init(location: 0, length: rendered.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                    }
                }
                let attributed = rtf.flatMap {
                    try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                }
                combined.append(attributed?.string == note.text ? attributed! : NSAttributedString(string: note.text))
                combined.append(NSAttributedString(string: "\n"))
                links += note.inlineLinks.map { link in
                    var shifted = LegacyInlineLink(range: .init(location: link.range.location + offset, length: link.range.length),
                        label: link.label, sourceName: link.sourceName, target: link.target)
                    shifted.role = link.role; return shifted
                }
                graphics += note.graphics.map { $0.offsettingCharacters(by: offset) }
            }
            let text = combined.string
            let rtf = try combined.data(from: .init(location: 0, length: combined.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            var locations: [String: Int] = [:]
            // A verse without its own note stays within this chapter at the
            // preceding note. All the chapter's notes remain available to read.
            var preceding = 0
            for reference in references {
                if let ordinal = source.commentaryOrdinals[reference.normalizedKey], let offset = offsets[ordinal] { preceding = offset }
                locations[reference.normalizedKey] = preceding
            }
            result = .init(destination: .init(ordinal: source.destination.ordinal, commentaryChapter: key), text: text,
                sectionCount: source.sectionCount, entries: source.entries,
                content: .imported(text: text, ordinal: source.destination.ordinal, anchors: [], rtf: rtf),
                graphics: graphics, inlineLinks: links, commentaryLocations: locations,
                commentaryPrevious: chapterIndex.flatMap { $0 > 0 ? chapters[$0 - 1] : nil },
                commentaryNext: chapterIndex.flatMap { $0 + 1 < chapters.count ? chapters[$0 + 1] : nil })
            if commentaryChapters.values.reduce(0, { $0 + $1.count }) >= 4 { commentaryChapters.removeAll() }
            commentaryChapters[url, default: [:]][key] = result
        }
        result.destination.reference = requested.reference
        let offset = requested.reference.flatMap(LegacyPassageQuery.sourceReference).flatMap { result.commentaryLocations[$0.normalizedKey] } ?? 0
        result.selection = .init(location: offset, length: 0)
        return result
    }
}

@MainActor extension ReaderSession {
    func alignCommentary(to reference: String) {
        guard let key = LegacyPassageQuery.sourceReference(reference)?.normalizedKey,
              let offset = page?.commentaryLocations[key] else { return }
        if viewportCharacterOffset != offset {
            selectedRange = .init(location: offset, length: 0)
            viewportCharacterOffset = offset; selectionRequest += 1
        }
    }
}

@MainActor extension ReaderSession {
    func findInCommentaryChapter(_ direction: ReaderFindDirection, position: Int) -> Bool {
        guard let page, page.destination.commentaryChapter != nil else { return false }
        let length = page.text.utf16.count, position = min(max(0, position), page.text.utf16.count)
        let forward = direction == .forward
        let primary = NSRange(location: forward ? position : 0, length: forward ? length - position : position)
        let remainder = NSRange(location: forward ? 0 : position, length: forward ? position : length - position)
        do {
            var wrapped = false
            var range = try ReaderFindSource.match(page.text, query: findQuery, range: primary, direction: direction, options: findOptions)
            if range == nil && findOptions.wraps {
                range = try ReaderFindSource.match(page.text, query: findQuery, range: remainder, direction: direction, options: findOptions)
                wrapped = range != nil
            }
            if let range {
                selectedRange = range; viewportCharacterOffset = range.location; selectionRequest += 1
                findStatus = .found(wrapped: wrapped)
            } else { findStatus = .notFound }
        } catch { findStatus = .failed(error.localizedDescription) }
        return true
    }
}
