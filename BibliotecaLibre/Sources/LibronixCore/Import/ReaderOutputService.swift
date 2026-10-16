import Foundation

/// All output routes use a frozen document, independent of viewport selection,
/// note overlays or zoom. This service reads originals and never writes to them.
public actor ReaderOutputService {
    private let contentService = LegacyContentService()
    public init() {}
    public func prepare(_ resource: LibraryResource, sectionOrdinal: Int, expectedTextFingerprint: String,
                        request: ReaderOutputRequest = .reading, maximumArticles: Int = 256,
                        maximumCharacters: Int = 4_000_000) async throws -> ReaderOutputDocument {
        guard resource.format == .legacyLSF else { throw ReaderOutputError.unsupportedFormat }
        let file = resource.location, lix = resource.indexLocation ?? file.deletingPathExtension().appendingPathExtension("LIX")
        let before = try LegacyGraphicsService.fileStamp(file), indexBefore = try LegacyGraphicsService.fileStamp(lix)
        let pair = try LegacyResourceReader.inspect(lsfURL: file, lixURL: lix)
        guard pair.identifiersMatch == true, pair.lsf.bkidHex?.lowercased() == resource.legacyIdentifier?.lowercased() else {
            throw LegacyLocatorError.resourceMismatch
        }
        let originalID = LegacyNumericResourceID.fromBKIDHex(pair.lsf.bkidHex)?.identifier
        let typography = try LegacyTypographyReader.inspect(lsfURL: file)
        let active = try await contentService.read(file, ordinal: sectionOrdinal)
        guard LibrarySearchService.textFingerprint(active.plainText) == expectedTextFingerprint else { throw LegacyIndicesError.sourceChanged }
        var scope = ReaderOutputScope.article, label = "Artículo \(sectionOrdinal + 1)", sections = [active]
        var selection: SearchTextRange?
        switch request {
        case let .selection(range):
            guard range.length > 0, valid(range, in: active.plainText) else { throw ReaderOutputError.invalidSelection }
            selection = range; scope = .selection; label = "Selección"
        case .reading:
            let directory = try await contentService.directory(file, indexURL: lix)
            let markers = directory.entries.compactMap { entry -> ChapterMarker? in
                guard entry.level > 0, let label = entry.positionLabel, let chapter = ChapterMarker(label: label, article: entry.sectionOrdinal) else { return nil }
                return chapter
            }
            if let start = markers.filter({ $0.article <= sectionOrdinal }).max(by: { $0.article < $1.article }) {
                let alternatives = Set(markers.filter { $0.article == start.article }.map { "\($0.key) \($0.chapter)" })
                guard alternatives.count == 1 else { throw ReaderOutputError.ambiguousChapter }
                let end = markers.filter { $0.article > start.article }.map(\.article).min() ?? directory.sections.sections.count
                guard sectionOrdinal < end, maximumArticles > 0, end - start.article <= maximumArticles else { throw ReaderOutputError.limitExceeded }
                sections = []
                var characterCount = 0
                for ordinal in start.article..<end {
                    try Task.checkCancellation()
                    let part = ordinal == sectionOrdinal ? active : try await contentService.read(file, ordinal: ordinal)
                    characterCount += part.plainText.utf16.count
                    guard characterCount <= maximumCharacters else { throw ReaderOutputError.limitExceeded }
                    sections.append(part)
                }
                try verifyChapter(sections, marker: start)
                scope = .chapter; label = "\(start.book) \(start.chapter)"
            }
        }
        guard sections.count <= maximumArticles, sections.reduce(0, { $0 + $1.plainText.utf16.count }) <= maximumCharacters else {
            throw ReaderOutputError.limitExceeded
        }
        var paragraphs: [ReaderOutputParagraph] = [], sources: [ReaderOutputSource] = [], references: [String] = []
        for section in sections {
            try Task.checkCancellation()
            // These structures remain explicit failures until their output
            // mapping is verified; text alone cannot stand in for an image.
            guard section.tables.isEmpty, section.graphics.isEmpty, section.markers.isEmpty,
                  section.paragraphs.allSatisfy({ $0.kind == .text && $0.label == nil }) else { throw ReaderOutputError.unsupportedContent }
            let range = selection ?? SearchTextRange(location: 0, length: section.plainText.utf16.count)
            guard let firstParagraph = section.paragraphs.first else { throw ReaderOutputError.unsupportedContent }
            let target = selection.map { [(firstParagraph, $0)] } ?? sourceParagraphs(section)
            for (paragraph, selected) in target {
                guard valid(selected, in: section.plainText) else { throw ReaderOutputError.invalidSelection }
                let text = (section.plainText as NSString).substring(with: selected.nsRange)
                let paragraphStyle = typography.paragraphStyle(paragraph.styleIdentifier)
                guard paragraphStyle != nil else { throw LegacyTypographyError.invalidTable }
                var spans: [ReaderOutputSpan] = []
                for run in section.runs {
                    let source = SearchTextRange(location: run.characterOffset, length: run.logicalCharacterCount)
                    let start = max(source.location, selected.location), end = min(source.upperBound, selected.upperBound)
                    if start < end {
                        guard let style = typography.characterStyle(run.styleIdentifier) else { throw LegacyTypographyError.invalidTable }
                        spans.append(.init(range: .init(location: start - selected.location, length: end - start), style: style))
                    }
                }
                paragraphs.append(.init(text: text, style: scope == .selection ? nil : paragraphStyle, spans: spans))
            }
            let eligible = section.anchors.filter { $0.dataTypeCode == 2 && $0.characterOffset < range.upperBound }
            let anchors = selection == nil ? eligible : eligible.filter { $0.characterOffset > range.location || $0 == eligible.last(where: { $0.characterOffset <= range.location }) }
            for anchor in anchors {
                guard let reference = anchor.reference, LegacyPassageQuery.parse(reference) != nil else { continue }
                if references.last != reference { references.append(reference) }
            }
            sources.append(.init(sectionOrdinal: section.descriptor.ordinal, decodedTextSHA256: LibrarySearchService.textFingerprint(section.plainText), selectedRange: range))
        }
        try Task.checkCancellation()
        guard try LegacyGraphicsService.fileStamp(file) == before, try LegacyGraphicsService.fileStamp(lix) == indexBefore else {
            throw LegacyIndicesError.sourceChanged
        }
        return ReaderOutputDocument(resourceID: resource.id, originalResourceID: originalID, title: resource.title, scope: scope,
            scopeLabel: label, references: references, paragraphs: paragraphs, sources: sources, typography: typography,
            bibliographicCitation: citation(pair.lsf, title: resource.title), createdUTC: Date())
    }

    private struct ChapterMarker {
        let article: Int
        let book: String
        let chapter: Int
        let key: String
        init?(label: String, article: Int) {
            let parts = label.components(separatedBy: ".CH")
            guard parts.count == 2, !parts[0].isEmpty, let chapter = Int(parts[1]), chapter > 0,
                  String(chapter) == parts[1], let reference = LegacyPassageQuery.parse("\(parts[0]) \(chapter):1") else { return nil }
            self.article = article; book = parts[0]; self.chapter = chapter; key = reference.sourceBookKey
        }
    }
    private func verifyChapter(_ sections: [LegacySectionContent], marker: ChapterMarker) throws {
        var previous = 0
        for section in sections {
            for anchor in section.anchors where anchor.dataTypeCode == 2 {
                guard let reference = anchor.reference, let query = LegacyPassageQuery.parse(reference), query.sourceBookKey == marker.key,
                      query.chapter == marker.chapter else { throw ReaderOutputError.invalidChapter }
                guard query.verse == previous || query.verse == previous + 1 else { throw ReaderOutputError.incompleteChapter }
                previous = query.verse
            }
        }
        guard previous > 0 else { throw ReaderOutputError.invalidChapter }
    }
    private func valid(_ range: SearchTextRange, in text: String) -> Bool {
        guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location, Range(range.nsRange, in: text) != nil else { return false }
        let source = text as NSString
        return [range.location, range.upperBound].allSatisfy { $0 == source.length || source.rangeOfComposedCharacterSequence(at: $0).location == $0 }
    }
    private func sourceParagraphs(_ section: LegacySectionContent) -> [(LegacyParagraph, SearchTextRange)] {
        section.paragraphs.map { paragraph in
            let start = paragraph.characterOffset, end = start + paragraph.text.utf16.count
            return (paragraph, .init(location: start, length: end - start))
        }
    }
    private func citation(_ metadata: LegacyMetadata, title: String) -> String {
        let parts = (metadata.publication ?? "").components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func clean(_ value: String) -> String { value.trimmingCharacters(in: CharacterSet(charactersIn: " :,;.")) }
        if parts.count == 3 {
            return "\(title). \(clean(parts[2])). \(clean(parts[0])): \(clean(parts[1]))."
        }
        let publication = metadata.publication.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        return title + "." + (publication.map { " " + $0 + "." } ?? "")
    }
}
