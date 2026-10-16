import Foundation

/// Pure catalog filtering. This is intentionally separate from searching book
/// content: catalog fields cannot stand in for a full-text search engine.
public struct CatalogQuery: Sendable {
    public var text: String
    public var format: ResourceFormat?
    public var includeHelp: Bool
    public var metadataOnly: Bool

    public init(text: String = "", format: ResourceFormat? = nil,
                includeHelp: Bool = true, metadataOnly: Bool = false) {
        self.text = text
        self.format = format
        self.includeHelp = includeHelp
        self.metadataOnly = metadataOnly
    }

    public func apply(to resources: [LibraryResource]) -> [LibraryResource] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return resources.filter { resource in
            guard includeHelp || !resource.isHelp,
                  format == nil || resource.format == format,
                  !metadataOnly || resource.provenance == .legacyPublicMetadata else { return false }
            if needle.isEmpty { return true }
            let haystack = [resource.title, resource.author ?? "", resource.fileName,
                            resource.languages.joined(separator: " ")].joined(separator: "\n")
            return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}
