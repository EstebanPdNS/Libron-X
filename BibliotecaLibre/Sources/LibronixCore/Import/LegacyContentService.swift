import Foundation

/// Actor boundary for bounded read-only content operations. Book text is never
/// persisted by this service. One checked index is cached, keyed by both source
/// URLs, file sizes and modification times, to keep navigation responsive.
public actor LegacyContentService {
    private struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date
    }
    private struct CachedSections {
        let url: URL
        let stamp: FileStamp
        let index: LegacySectionIndex
    }
    private struct CachedIndices {
        let lsfURL: URL
        let lixURL: URL
        let lsfStamp: FileStamp
        let lixStamp: FileStamp
        let index: LegacyIndicesInspection
        let linkLookup: LegacyNamedPositionLookup
        let allowUnavailableIndexBlocks: Bool
    }
    private var sectionCache: CachedSections?
    private var indicesCache: CachedIndices?

    public init() {}

    public func inspect(_ url: URL) throws -> LegacySectionIndex {
        try Task.checkCancellation()
        let before = try stamp(url)
        if let cached = sectionCache, cached.url == url, cached.stamp == before { return cached.index }
        let result = try LegacyContentReader.inspectSections(lsfURL: url)
        try Task.checkCancellation()
        guard try stamp(url) == before else { throw LegacyIndicesError.sourceChanged }
        sectionCache = CachedSections(url: url, stamp: before, index: result)
        return result
    }

    public func read(_ url: URL, ordinal: Int) throws -> LegacySectionContent {
        let index = try inspect(url)
        guard ordinal >= 0, ordinal < index.sections.count else { throw LegacyContentError.sectionNotFound(ordinal) }
        let before = try stamp(url)
        let result = try LegacyContentReader.readSection(lsfURL: url, descriptor: index.sections[ordinal],
                                                         tartEnd: index.tartOffset + index.tartLength)
        try Task.checkCancellation()
        guard try stamp(url) == before else { throw LegacyIndicesError.sourceChanged }
        return result
    }

    public func directory(_ url: URL, indexURL: URL? = nil, allowUnavailableIndexBlocks: Bool = false) throws -> LegacyArticleDirectory {
        let index = try indices(url, indexURL: indexURL, allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
        try Task.checkCancellation()
        return LegacyIndicesReader.articleDirectory(index: index)
    }

    /// Resolve only literal run attributes present in this resource's checked
    /// named-position index. Both legacy and extended string storage are read.
    public func inlineLinks(_ url: URL, content: LegacySectionContent, indexURL: URL? = nil,
                            allowUnavailableIndexBlocks: Bool = false) throws -> LegacyInlineLinkResolution {
        let index = try indices(url, indexURL: indexURL, allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
        try Task.checkCancellation()
        return LegacyInlineLinks.resolve(content: content, lookup: indicesCache?.linkLookup ?? LegacyNamedPositionLookup(index.namedPositions))
    }

    /// `directoryRow` identifies an AIDX source row, never a physical article ID.
    public func read(_ url: URL, directoryRow: Int, indexURL: URL? = nil) throws -> LegacySectionContent {
        let index = try indices(url, indexURL: indexURL)
        guard index.articles.indices.contains(directoryRow) else { throw LegacyIndicesError.directoryRowNotFound(directoryRow) }
        return try read(url, ordinal: Int(index.articles[directoryRow].articleID))
    }

    public func resolvePassage(_ url: URL, indexURL: URL? = nil, reference: String,
                                maximumCandidates: Int = 256, allowUnavailableIndexBlocks: Bool = false) throws -> LegacyReferenceResolution {
        guard let query = LegacyPassageQuery.parse(reference) else { throw LegacyIndicesError.invalidObservedReference }
        let index = try indices(url, indexURL: indexURL, allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
        let before = try stamp(url)
        let result = try LegacyIndicesReader.resolvePassage(lsfURL: url, index: index, query: query,
                                                             maximumCandidates: maximumCandidates)
        try Task.checkCancellation()
        guard try stamp(url) == before else { throw LegacyIndicesError.sourceChanged }
        return result
    }

    public func navigationArticles(_ url: URL, indexURL: URL? = nil, allowUnavailableIndexBlocks: Bool = false) throws -> [Int] {
        let index = try indices(url,indexURL:indexURL,allowUnavailableIndexBlocks:allowUnavailableIndexBlocks)
        return (index.articleReferenceRanges.isEmpty ? index.articles.map(\.articleID) : index.articleReferenceRanges.map(\.articleID)).map(Int.init)
    }

    public func referencePositions(_ url: URL, indexURL: URL? = nil, allowUnavailableIndexBlocks: Bool = false) throws -> [LegacyReferencePosition] {
        try indices(url,indexURL:indexURL,allowUnavailableIndexBlocks:allowUnavailableIndexBlocks).referencePositions
    }

    public func clearCache() {
        sectionCache = nil
        indicesCache = nil
    }

    /// Translate only a decoded article whose CCCT length agrees with the
    /// native UTF-16 projection. Original hints provide an additional edition
    /// check; unresolved structures and changed context remain explicit errors.
    public func resolveArticleLocator(_ resource: LibraryResource, originalResourceID: String,
                                      position: String, context: [String: String] = [:]) throws -> LegacyLocatorResolution {
        guard resource.format == .legacyLSF,
              LegacyNumericResourceID.fromBKIDHex(resource.legacyIdentifier)?.identifier == originalResourceID else {
            throw LegacyLocatorError.resourceMismatch
        }
        if let id = context["id"], id != originalResourceID { throw LegacyLocatorError.resourceMismatch }
        let url = resource.location, lix = resource.indexLocation ?? url.deletingPathExtension().appendingPathExtension("LIX")
        let before = try LegacyGraphicsService.fileStamp(url), indexBefore = try LegacyGraphicsService.fileStamp(lix)
        let pair = try LegacyResourceReader.inspect(lsfURL: url, lixURL: lix)
        guard pair.identifiersMatch == true,
              LegacyNumericResourceID.fromBKIDHex(pair.lsf.bkidHex) == LegacyNumericResourceID.fromBKIDHex(resource.legacyIdentifier) else {
            throw LegacyLocatorError.resourceMismatch
        }
        let index = try indices(url, indexURL: lix)
        let counts = try LegacyCharacterCounts.inspect(lsfURL: url, lixURL: lix, articleCount: index.sections.sections.count)
        let locator = try LegacyArticleLocator.parse(position)
        var article = locator.articleID
        if let label = locator.articleLabel {
            if index.namedPositions.first(where: { $0.articleID == article })?.label != label {
                let matches = index.namedPositions.filter { $0.label == label }
                guard matches.count == 1, let matched = matches.first else { throw LegacyLocatorError.ambiguousLabel }
                article = matched.articleID
            }
        }
        let absolute = try locator.absoluteCoordinates(articleID: article)
        let content = try read(url, ordinal: Int(absolute.articleID))
        let sourceCount = try counts.count(articleID: absolute.articleID), projected = content.plainText.utf16.count
        guard content.expectedCharacterCount == sourceCount, UInt64(projected) == UInt64(sourceCount) else { throw LegacyLocatorError.incompatibleProjection }
        guard absolute.offset <= sourceCount, absolute.length <= sourceCount - absolute.offset else { throw LegacyLocatorError.outsideArticle }
        let range = SearchTextRange(location: Int(absolute.offset), length: Int(absolute.length))
        guard Range(range.nsRange, in: content.plainText) != nil else { throw LegacyLocatorError.incompatibleProjection }
        try LegacyLocatorResolution.checkContext(context, text: content.plainText, range: range)
        try Task.checkCancellation()
        guard try LegacyGraphicsService.fileStamp(url) == before, try LegacyGraphicsService.fileStamp(lix) == indexBefore else { throw LegacyIndicesError.sourceChanged }
        let reference = content.anchors.last(where: { $0.characterOffset <= range.location })?.reference
        let location = ReaderLocation(resourceID: resource.id, legacyIdentifier: resource.legacyIdentifier, format: resource.format,
            sectionOrdinal: Int(absolute.articleID), reference: reference, textFingerprint: LibrarySearchService.textFingerprint(content.plainText), characterOffset: range.location)
        return LegacyLocatorResolution(location: location, range: range, sourceCharacterCount: sourceCount)
    }

    private func indices(_ url: URL, indexURL: URL?, allowUnavailableIndexBlocks: Bool = false) throws -> LegacyIndicesInspection {
        try Task.checkCancellation()
        let lix = indexURL ?? url.deletingPathExtension().appendingPathExtension("LIX")
        let lsfStamp = try stamp(url), lixStamp = try stamp(lix)
        if let cached = indicesCache, cached.lsfURL == url, cached.lixURL == lix,
           cached.lsfStamp == lsfStamp, cached.lixStamp == lixStamp,
           cached.allowUnavailableIndexBlocks == allowUnavailableIndexBlocks { return cached.index }
        let result = try LegacyIndicesReader.inspect(lsfURL: url, lixURL: lix, allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
        try Task.checkCancellation()
        guard try stamp(url) == lsfStamp, try stamp(lix) == lixStamp else { throw LegacyIndicesError.sourceChanged }
        indicesCache = CachedIndices(lsfURL: url, lixURL: lix, lsfStamp: lsfStamp, lixStamp: lixStamp, index: result, linkLookup: LegacyNamedPositionLookup(result.namedPositions),
                                    allowUnavailableIndexBlocks: allowUnavailableIndexBlocks)
        sectionCache = CachedSections(url: url, stamp: lsfStamp, index: result.sections)
        return result
    }

    private func stamp(_ url: URL) throws -> FileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { throw LegacyIndicesError.sourceChanged }
        return FileStamp(size: size.uint64Value, modified: modified)
    }
}
