import Foundation

/// A search-specific adapter, leaving the content/index reader unchanged.
/// Stamps surround the entire resource scan as well as each individual read.
actor LibrarySearchReader: LibrarySearchContentProvider {
    let contentService: LegacyContentService
    private var embeddedSources: [String: LibraryResource] = [:]

    init(contentService: LegacyContentService) { self.contentService = contentService }

    func prepare(_ resource: LibraryResource) async throws -> LibrarySearchPreparedResource {
        try Task.checkCancellation()
        if resource.format == .libronixLLS {
            let original = try stamp(resource.location)
            let inner = try await LibronixBookService.shared.prepare(resource)
            let prepared = try await prepare(inner)
            let result = LibrarySearchPreparedResource(articles: prepared.articles,
                sourceStamps: prepared.sourceStamps + [original], warnings: prepared.warnings)
            try verify(result); embeddedSources[resource.id] = inner
            return result
        }
        let sourceStamp = try stamp(resource.location)
        let sectionIndex = try await contentService.inspect(resource.location)
        let indexURL = resource.indexLocation ?? resource.location.deletingPathExtension().appendingPathExtension("LIX")
        var stamps = [sourceStamp]
        var warnings: [String] = []
        var titles: [Int: String] = [:]
        if FileManager.default.fileExists(atPath: indexURL.path) {
            stamps.append(try stamp(indexURL))
            do {
                let directory = try await contentService.directory(resource.location, indexURL: indexURL)
                for entry in directory.entries where titles[entry.sectionOrdinal] == nil {
                    titles[entry.sectionOrdinal] = entry.displayTitle
                }
                warnings.append(contentsOf: directory.warnings)
            } catch is CancellationError { throw CancellationError() }
            catch let error as LegacyIndicesError where error == .sourceChanged { throw error }
            catch {
                warnings.append("No se pudo interpretar el directorio LIX; se buscan las secciones físicas con etiquetas de navegación: \(error.localizedDescription)")
            }
        } else {
            warnings.append("No hay directorio LIX disponible; los títulos de artículo son etiquetas de navegación por sección física.")
        }
        let prepared = LibrarySearchPreparedResource(
            articles: sectionIndex.sections.map {
                .init(sectionOrdinal: $0.ordinal, title: titles[$0.ordinal] ?? "Artículo \($0.ordinal + 1)")
            }, sourceStamps: stamps, warnings: warnings)
        try verify(prepared)
        return prepared
    }

    func read(_ resource: LibraryResource, article: LibrarySearchArticleDescriptor,
              prepared: LibrarySearchPreparedResource) async throws -> LibrarySearchDecodedArticle {
        try verify(prepared)
        let content = try await contentService.read((embeddedSources[resource.id] ?? resource).location, ordinal: article.sectionOrdinal)
        try verify(prepared)
        guard content.descriptor.ordinal == article.sectionOrdinal else { throw LibrarySearchError.invalidArticleDirectory }
        return .init(text: content.plainText, warnings: content.warnings, referenceAnchors: content.anchors)
    }

    func verifyUnchanged(_ resource: LibraryResource, prepared: LibrarySearchPreparedResource) async throws {
        try verify(prepared)
    }

    private func verify(_ prepared: LibrarySearchPreparedResource) throws {
        try Task.checkCancellation()
        for original in prepared.sourceStamps {
            do {
                guard try stamp(original.url) == original else { throw LegacyIndicesError.sourceChanged }
            } catch is CancellationError { throw CancellationError() }
            catch { throw LegacyIndicesError.sourceChanged }
        }
    }

    private func stamp(_ url: URL) throws -> LibrarySearchFileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else {
            throw LegacyIndicesError.sourceChanged
        }
        return .init(url: url, size: size.uint64Value, modified: modified,
                     fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}
