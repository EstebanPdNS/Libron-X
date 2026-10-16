import Foundation

/// Source-bound topical keys and checked AIDX destinations. Neither directory
/// row numbers nor unchecked numeric ordinals are substituted for article IDs.
public struct LibronixTopicCatalog: Sendable {
    public let indexes: [LibronixNamedTopicIndex]
    public let sourceStamp: LegacyGraphicSourceStamp
    private let destinations: [UInt32: LegacyArticleDirectoryEntry]

    init(indexes: [LibronixNamedTopicIndex], directory: LegacyArticleDirectory,
         sourceStamp: LegacyGraphicSourceStamp) throws {
        var destinations: [UInt32: LegacyArticleDirectoryEntry] = [:]
        for entry in directory.entries {
            try Task.checkCancellation()
            guard entry.sectionOrdinal == Int(entry.articleID),
                  entry.sectionOrdinal < directory.sections.sections.count,
                  directory.sections.sections[entry.sectionOrdinal] == entry.section else {
                throw LibronixTopicIndexFailure.malformed
            }
            if let previous = destinations[entry.articleID] {
                guard previous.section == entry.section else { throw LibronixTopicIndexFailure.malformed }
                // Multiple labels may target one original physical article.
                if entry.directoryRow < previous.directoryRow { destinations[entry.articleID] = entry }
            } else { destinations[entry.articleID] = entry }
        }
        guard indexes.allSatisfy({ $0.labelsByReferent.keys.allSatisfy { destinations[$0] != nil } }) else {
            throw LibronixTopicIndexFailure.malformed
        }
        self.indexes = indexes; self.sourceStamp = sourceStamp; self.destinations = destinations
    }

    public func articles(index: Int, topic: Int) throws -> [LegacyArticleDirectoryEntry] {
        guard indexes.indices.contains(index), indexes[index].topics.indices.contains(topic) else {
            throw LibronixTopicIndexFailure.malformed
        }
        var seen = Set<UInt32>()
        return try indexes[index].topics[topic].referents.compactMap { id in
            try Task.checkCancellation()
            guard seen.insert(id).inserted else { return nil }
            guard let entry = destinations[id] else { throw LibronixTopicIndexFailure.malformed }
            return entry
        }
    }

    public func matching(_ prefix: String, maximum: Int) throws -> [(index: Int, topic: Int)] {
        guard maximum > 0 else { return [] }
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle.utf16.count <= 512 else { return [] }
        var matches: [(Int, Int)] = []
        for (index, named) in indexes.enumerated() {
            for (topic, entry) in named.topics.enumerated() {
                try Task.checkCancellation()
                // Some original dictionary keys begin with whitespace followed
                // by combining marks. Normalize only the comparison boundary;
                // keep the complete original key and its identity in results.
                if entry.text.trimmingCharacters(in:.whitespacesAndNewlines).range(of: needle, options: [.anchored, .caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")) != nil {
                    matches.append((index, topic))
                    if matches.count >= maximum { return matches }
                }
            }
        }
        return matches
    }
}

/// One parsed catalog is cached at a time. Heavy source decoding and matching
/// stay on this actor; the Mac UI receives bounded matches and article metadata.
public actor LibronixTopicCatalogService {
    public static let shared = LibronixTopicCatalogService()
    private var cached: (URL, LibronixTopicCatalog)?
    // Topic catalog scans can extract large map resources. Keep their cache
    // and extraction queue separate from foreground reader preparation.
    private let books = LibronixBookService()
    public init() {}
    public func catalog(_ resource: LibraryResource) async throws -> LibronixTopicCatalog? {
        try Task.checkCancellation()
        guard resource.format == .libronixLLS else { return nil }
        let stamp = try LegacyGraphicsService.fileStamp(resource.location)
        if let cached, cached.0 == resource.location, cached.1.sourceStamp == stamp { return cached.1 }
        let archive = try LibronixBookArchive.inspect(at: resource.location)
        guard !(try archive.metadata().declaredTopicIndexes.isEmpty) else { return nil }
        let indexes = try LibronixTopicIndexReader.read(archive.readEntry("fullindex.dat", maximumBytes:32*1024*1024))
        let prepared = try await books.prepare(resource)
        guard let indexURL = prepared.indexLocation else { throw LibronixBookError.missingText }
        let index = try LegacyIndicesReader.inspect(lsfURL:prepared.location,lixURL:indexURL,allowUnavailableIndexBlocks:true)
        let result = try LibronixTopicCatalog(indexes:indexes,directory:LegacyIndicesReader.articleDirectory(index:index),sourceStamp:stamp)
        try Task.checkCancellation()
        guard try LegacyGraphicsService.fileStamp(resource.location) == stamp else { throw LibronixBookError.sourceChanged }
        cached = (resource.location, result)
        return result
    }
    public func matching(_ catalog: LibronixTopicCatalog, prefix: String, maximum: Int) throws -> [(index: Int, topic: Int)] {
        try catalog.matching(prefix, maximum:maximum)
    }
    public func articles(_ catalog: LibronixTopicCatalog, index: Int, topic: Int) throws -> [LegacyArticleDirectoryEntry] {
        try catalog.articles(index:index,topic:topic)
    }
}
