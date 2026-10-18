import Foundation
import LibronixCore

/// Global search uses the same independent text/DOM projections as visible
/// readers. The portable Core's default legacy provider remains unchanged.
actor WorkspaceSearchReader: LibrarySearchContentProvider {
    private let nativeReader = LibronNativeReader()

    func supports(_ resource: LibraryResource) async -> Bool {
        [.legacyLSF, .libronixLLS, .libronixOEB, .eSwordSQLite, .epub, .libronDictionary].contains(resource.format)
    }

    private func page(_ resource: LibraryResource, ordinal: Int) async throws -> ReaderPage {
        if LibronNativeReader.location(resource) != nil {
            return try await nativeReader.read(resource, .init(ordinal: ordinal))
        }
        return try await ReaderSession.readOriginal(resource, .init(ordinal: ordinal))
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
        let result = LibrarySearchPreparedResource(articles: (0..<first.sectionCount).map {
            .init(sectionOrdinal: $0, title: titles[$0] ?? resource.title + " · " + String($0 + 1))
        }, sourceStamps: stamps, warnings: [])
        try await verifyUnchanged(resource, prepared: result)
        return result
    }

    func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor,
              prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
        try await verifyUnchanged(resource, prepared: prepared)
        let result = try await page(resource, ordinal: article.sectionOrdinal)
        guard result.destination.ordinal == article.sectionOrdinal else { throw LibrarySearchError.invalidArticleDirectory }
        let warnings = result.warning.map { [$0] } ?? []
        let decoded: LibrarySearchDecodedArticle
        if let html = result.oeb {
            guard let path = html.book.path(for: html.url) else { throw LibronixBookError.invalidDirectory }
            let projection = try await ReaderOEBTextSource.shared.read(book: html.book, path: path, viewport: .init())
            guard let range = projection.articleRanges[article.sectionOrdinal] else { throw LibrarySearchError.invalidArticleDirectory }
            decoded = .init(text: projection.text, warnings: warnings,
                            searchRange: .init(location: range.location, length: range.length))
        } else {
            let anchors = result.content?.anchors ?? []
            if resource.format == .eSwordSQLite {
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
                decoded = .init(text: result.text, warnings: warnings, bibleVerses: verses)
            } else {
                decoded = .init(text: result.text, warnings: warnings, referenceAnchors: anchors)
            }
        }
        try await verifyUnchanged(resource, prepared: prepared)
        return decoded
    }

    func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
        try LibrarySearchFileStamp.verify(prepared.sourceStamps)
    }
}
