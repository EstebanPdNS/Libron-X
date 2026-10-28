import Foundation
import LibronixCore

/// Global search uses the same independent text/DOM projections as visible
/// readers, including their checked native Bible-link destinations.
actor WorkspaceSearchReader: LibrarySearchContentProvider {
    private let nativeReader = LibronNativeReader()
    private let sourceFields = WorkspaceSearchFields()

    func supports(_ resource: LibraryResource) async -> Bool {
        [.legacyLSF, .libronixLLS, .libronixOEB, .eSwordSQLite, .epub, .libronDictionary].contains(resource.format)
    }

    private func page(_ resource: LibraryResource, ordinal: Int, verifiedDictionaryCount: Int? = nil) async throws -> ReaderPage {
        if LibronNativeReader.location(resource) != nil {
            return try await nativeReader.read(resource, .init(ordinal: ordinal))
        }
        return try await ReaderSession.readOriginal(resource, .init(ordinal: ordinal), verifiedDictionaryCount: verifiedDictionaryCount)
    }

    func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
        try Task.checkCancellation()
        var urls = [resource.location]
        if let index = resource.indexLocation, FileManager.default.fileExists(atPath: index.path) { urls.append(index) }
        if let package = resource.packageLocation { urls.append(package.appendingPathComponent("manifest.json")) }
        if let native = LibronNativeReader.location(resource) { urls.append(native) }
        let stamps = try urls.map(LibrarySearchFileStamp.capture)
        let first = try await page(resource, ordinal: 0)
        guard first.sectionCount > 0, first.sectionCount <= 2_000_000 else { throw LibrarySearchError.invalidArticleDirectory }
        var titles: [Int: String] = [:]
        for entry in first.entries where titles[entry.ordinal] == nil { titles[entry.ordinal] = entry.title }
        let fields: [SearchField]
        let nativeEPUBBible = resource.format == .epub && first.oeb == nil &&
            resource.libron?.resourceType == "Biblia" && !(first.content?.anchors.isEmpty ?? true)
        if nativeEPUBBible { fields = [.body, .title, .bibleText] }
        else { switch resource.format {
        case .libronixOEB, .epub: fields = [.body, .title, .heading, .footnote, .quotation]
        case .libronDictionary: fields = [.body, .title]
        case .eSwordSQLite: fields = (first.content?.anchors.isEmpty == false) ? [.body, .title, .bibleText] : [.body, .title]
        default: fields = [.body, .title, .bibleText]
        }
        }
        let result: LibrarySearchPreparedResource
        if resource.format == .libronDictionary && first.entries.isEmpty {
            result = .init(contiguousArticleCount: first.sectionCount, titlePrefix: resource.title,
                           sourceStamps: stamps, projectionVersion: "workspace-search-block-boundaries-v5", availableFields: fields)
        } else { result = LibrarySearchPreparedResource(articles: (0..<first.sectionCount).map {
            .init(sectionOrdinal: $0, title: titles[$0] ?? resource.title + " · " + String($0 + 1))
        }, sourceStamps: stamps, warnings: [], projectionVersion: "workspace-search-block-boundaries-v5", availableFields: fields) }
        try await verifyUnchanged(resource, prepared: result)
        return result
    }

    func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor,
              prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
        try await verifyUnchanged(resource, prepared: prepared)
        let result = try await page(resource, ordinal: article.sectionOrdinal, verifiedDictionaryCount: prepared.articleCount)
        guard result.destination.ordinal == article.sectionOrdinal else { throw LibrarySearchError.invalidArticleDirectory }
        let warnings = result.warning.map { [$0] } ?? []
        let decoded: LibrarySearchDecodedArticle
        if let html = result.oeb {
            guard let path = html.book.path(for: html.url) else { throw LibronixBookError.invalidDirectory }
            let projection = try await ReaderOEBTextSource.shared.read(book: html.book, path: path, viewport: .init())
            guard let range = projection.articleRanges[article.sectionOrdinal] else { throw LibrarySearchError.invalidArticleDirectory }
            decoded = .init(text: projection.text, warnings: warnings,
                            searchRange: .init(location: range.location, length: range.length), referenceLinks: projection.referenceLinks,
                            fieldDirectory: try await sourceFields.directory(resource, ordinal: article.sectionOrdinal, text: projection.text, stamps: prepared.sourceStamps,
                                html: html, rendered: projection.fieldDirectory, visibleRange: .init(location: range.location, length: range.length)),
                            lexicalBreaks: projection.lexicalBreaks)
        } else {
            let anchors = result.content?.anchors ?? []
            let links = result.inlineLinks.compactMap(BibleReferenceSourceLink.init)
            let fields: SearchFieldDirectory?
            if let provided = result.fieldDirectory { fields = provided }
            else { fields = try await sourceFields.directory(resource, ordinal: article.sectionOrdinal, text: result.text, stamps: prepared.sourceStamps, anchors: anchors) }
            let nativeEPUBBible = resource.format == .epub && resource.libron?.resourceType == "Biblia"
            if resource.format == .eSwordSQLite || nativeEPUBBible {
                // Native imported Bibles use explicit UTF-16 anchors regardless
                // of the retained source container. Do not interpret their zero
                // datatype as an unverified legacy reference.
                // e-Sword's authored reader anchors use datatype zero, not the
                // legacy driver's datatype two. Preserve them as explicit verse
                // intervals instead of relabeling the source's datatype.
                let entries = ReaderBibleIndex(anchors: anchors, textLength: result.text.utf16.count).entries
                let verses = try entries.indices.map { index -> LibrarySearchBibleVerse in
                    let entry = entries[index]
                    let end = index + 1 < entries.count ? entries[index + 1].offset : result.text.utf16.count
                    guard let reference = LegacyPassageQuery.sourceReference(entry.reference), end > entry.offset else {
                        throw LibrarySearchError.invalidVerseDirectory
                    }
                    return .init(reference: entry.reference, normalizedReference: reference.normalizedKey,
                                 range: .init(location: entry.offset, length: end - entry.offset))
                }
                let nativeFields: SearchFieldDirectory? = nativeEPUBBible ? .init(
                    regions: [.body: result.text.isEmpty ? [] : [.init(location: 0, length: result.text.utf16.count)],
                              .bibleText: verses.map(\.range)],
                    externalValues: [.title: [article.title]]) : fields
                decoded = .init(text: result.text, warnings: warnings, bibleVerses: verses, referenceLinks: links, fieldDirectory: nativeFields)
            } else {
                decoded = .init(text: result.text, warnings: warnings, referenceAnchors: anchors, referenceLinks: links, fieldDirectory: fields)
            }
        }
        try await verifyUnchanged(resource, prepared: prepared)
        return decoded
    }

    func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
        try LibrarySearchFileStamp.verify(prepared.sourceStamps)
    }
}
