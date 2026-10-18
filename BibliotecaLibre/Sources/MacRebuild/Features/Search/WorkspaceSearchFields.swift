import Foundation
import LibronixCore

/// One generation-bound title map at a time. Body is the primary reader text;
/// neutral native flags never assign component heading/footnote roles.
actor WorkspaceSearchFields {
    private let legacy = LegacyContentService()
    private var lastID: String?
    private var lastFormat: ResourceFormat?
    private var lastStamps: [LibrarySearchFileStamp] = []
    private var titles: [Int: [String]]?
    func directory(_ resource: LibraryResource, ordinal: Int, text: String,
                   stamps: [LibrarySearchFileStamp], anchors: [LegacyReferenceAnchor] = [],
                   html: ReaderOEBPage? = nil, rendered: SearchFieldDirectory? = nil, visibleRange: SearchTextRange? = nil) async throws -> SearchFieldDirectory? {
        if let html {
            guard let rendered else { return nil }
            let source = text as NSString
            let scope = visibleRange ?? .init(location: 0, length: source.length)
            let visibleTitles = (rendered.regions[.title] ?? []).compactMap { range -> String? in
                let span = NSIntersectionRange(range.nsRange, scope.nsRange)
                return span.length > 0 ? source.substring(with: span) : nil
            }
            var external = rendered.externalValues ?? [:]
            var names = external[.title] ?? []
            if resource.format == .libronixOEB { names += html.book.directory.articles.filter { $0.ordinal == ordinal }.map(\.title) }
            var seen = Set<String>()
            external[.title] = names.filter { !$0.isEmpty && !visibleTitles.contains($0) && seen.insert($0).inserted }
            return .init(regions: rendered.regions, externalValues: external, witnessRegions: rendered.witnessRegions)
        }
        if resource.format == .libronDictionary {
            let entry = try LibronDictionaryDatabase.page(resource.location, ordinal: ordinal)
            guard entry.body == text else { return nil }
            return .init(regions: [.body: text.isEmpty ? [] : [.init(location: 0, length: text.utf16.count)]],
                         externalValues: [.title: [entry.headword]])
        }
        let requestedTitles: [Int: [String]]?
        if lastID == resource.id && lastFormat == resource.format && lastStamps == stamps { requestedTitles = titles }
        else {
            // Keep the local result immutable across actor reentrancy. Another
            // resource cannot pair its cached ID with these titles after await.
            requestedTitles = try await sourceTitles(resource)
            lastID = resource.id; lastFormat = resource.format; lastStamps = stamps; titles = requestedTitles
        }
        var regions: [SearchField: [SearchTextRange]] = [:]
        var units: [SearchField: [SearchTextRange]] = [:]
        if resource.format == .eSwordSQLite {
            if anchors.isEmpty { regions[.body] = text.isEmpty ? [] : [.init(location: 0, length: text.utf16.count)] }
            else if let body = Self.scriptureBodies(text, anchors: anchors) {
                regions[.body] = body; regions[.bibleText] = body
                units[.body] = [.init(location: 0, length: text.utf16.count)]; units[.bibleText] = units[.body]
            }
        }
        if [.legacyLSF, .libronixLLS].contains(resource.format) {
            regions[.body] = text.isEmpty ? [] : [.init(location: 0, length: text.utf16.count)]
        }
        guard !regions.isEmpty || requestedTitles != nil else { return nil }
        return .init(regions: regions, externalValues: requestedTitles.map { [.title: $0[ordinal] ?? []] }, witnessRegions: units)
    }
    private func sourceTitles(_ resource: LibraryResource) async throws -> [Int: [String]]? {
        do {
            if resource.format == .eSwordSQLite { return try ESwordResource.searchTitles(resource.location).mapValues { [$0] } }
            guard [.legacyLSF, .libronixLLS].contains(resource.format) else { return nil }
            let source = resource.format == .libronixLLS ? try await LibronixBookService.shared.prepare(resource) : resource
            let directory = try await legacy.directory(source.location, indexURL: source.indexLocation, allowUnavailableIndexBlocks: resource.format == .libronixLLS)
            var found: [Int: [String]] = [:]
            for row in directory.entries {
                if let title = row.title, !title.isEmpty, !found[row.sectionOrdinal, default: []].contains(title) {
                    found[row.sectionOrdinal, default: []].append(title)
                }
            }
            return found
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }
    /// ESwordReader's explicit numeric display prefix is not the Scripture
    /// column. Validate that producer contract before excluding its prefix.
    private static func scriptureBodies(_ text: String, anchors: [LegacyReferenceAnchor]) -> [SearchTextRange]? {
        let source = text as NSString
        var ranges: [SearchTextRange] = []
        for (index, anchor) in anchors.enumerated() {
            let start = anchor.characterOffset, end = index + 1 < anchors.count ? anchors[index + 1].characterOffset : source.length
            guard let ref = anchor.reference.flatMap(LegacyPassageQuery.sourceReference), start >= 0, end > start, end <= source.length else { return nil }
            let prefix = source.substring(with: .init(location: start, length: min(24, end - start)))
            guard let space = prefix.firstIndex(where: { $0.isWhitespace }), let number = Int(prefix[..<space]), number == ref.verse else { return nil }
            let offset = start + prefix[..<prefix.index(after: space)].utf16.count
            if end > offset { ranges.append(.init(location: offset, length: end - offset)) }
        }
        return ranges
    }
}
