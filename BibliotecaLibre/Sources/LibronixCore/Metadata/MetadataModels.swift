import Foundation

/// IDs use the original category/name, independent of the import folder.
/// GUID, file location and locale remain separate fields with provenance.
public struct MetadataIdentity: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let category: String?
    public let guid: String?
    public let version: String?
    public let creator: String?
    public let owner: String?
    public let source: URL
    public let titles: [String: String]
    public let descriptions: [String: String]
    public let attributes: [String: String]

    public var displayTitle: String { titles["es"] ?? titles["en"] ?? name }
}

public enum AssociationDefinitionState: String, Codable, Hashable, Sendable {
    case declaredGroups, obsoletePlaceholder, emptyDefinition
}

public struct ResourceAssociationGroup: Codable, Hashable, Sendable {
    public let guid: String?
    public let priority: Int?
    public let priorityText: String?
    public let type: String?
    public let resourceIDs: [String]
    public let attributes: [String: String]
}

public struct ResourceAssociation: Identifiable, Codable, Hashable, Sendable {
    public let identity: MetadataIdentity
    public let groups: [ResourceAssociationGroup]
    public let definitionState: AssociationDefinitionState
    public let sourceXML: XMLNode
    public var id: String { identity.id }
    public var name: String { identity.name }
    public var title: String { identity.displayTitle }
    public var resourceIDs: [String] { groups.flatMap(\.resourceIDs) }
}

/// A bounded source document retained as evidence, never executed or rewritten.
public struct ResourceAssociationDocument: Sendable {
    public let source: URL
    public let data: Data
    public let definition: ResourceAssociation
}

/// Only declared operators are interpreted. Unknown nodes remain round-trip
/// data and must not silently match every resource or become an empty filter.
public indirect enum ResourceFilter: Codable, Hashable, Sendable {
    case resource(id: String)
    case any([ResourceFilter])
    case all([ResourceFilter])
    case not(ResourceFilter)
    case unknown(XMLNode)

    public var referencedResourceIDs: [String] {
        switch self {
        case let .resource(id): [id]
        case let .any(filters), let .all(filters): filters.flatMap(\.referencedResourceIDs)
        case let .not(filter): filter.referencedResourceIDs
        case .unknown: []
        }
    }

    /// `nil` means the filter cannot yet be evaluated, not "no members".
    public func contains(resourceID: String) -> Bool? {
        switch self {
        case let .resource(id): return resourceID == id
        case let .any(filters):
            let results = filters.map { $0.contains(resourceID: resourceID) }
            if results.contains(true) { return true }
            if results.contains(where: { $0 == nil }) { return nil }
            return false
        case let .all(filters):
            let results = filters.map { $0.contains(resourceID: resourceID) }
            if results.contains(false) { return false }
            if results.contains(where: { $0 == nil }) { return nil }
            return true
        case let .not(filter): return filter.contains(resourceID: resourceID).map { !$0 }
        case .unknown: return nil
        }
    }
}

public struct ResourceCollection: Identifiable, Codable, Hashable, Sendable {
    public let identity: MetadataIdentity
    public let filter: ResourceFilter?
    public let commerceIDs: [String]
    public let sourceXML: XMLNode
    public var id: String { identity.id }
    public var name: String { identity.name }
    public var title: String { identity.displayTitle }
    /// References may occur inside NOT. Use contains(resourceID:) for membership.
    public var resourceIDs: [String] { filter?.referencedResourceIDs ?? [] }
    public func contains(resourceID: String) -> Bool? { filter?.contains(resourceID: resourceID) }
}

public struct VisualMarkupStyle: Codable, Hashable, Sendable {
    public let name: String
    public let version: String?
    public let titles: [String: String]
    public let attributes: [String: String]
    public let markup: XMLNode?
    public let sourceXML: XMLNode
    public var title: String { titles["es"] ?? titles["en"] ?? name }
}

public struct VisualMarkupPalette: Identifiable, Codable, Hashable, Sendable {
    public let identity: MetadataIdentity
    public let styles: [VisualMarkupStyle]
    public let sourceXML: XMLNode
    public var id: String { identity.id }
    public var name: String { identity.name }
    public var title: String { identity.displayTitle }
}

public struct BibleCopyFormat: Codable, Hashable, Sendable {
    public let name: String
    public let value: String?
    public let attributes: [String: String]
}

public struct BibleCopyTemplate: Codable, Hashable, Sendable {
    public let name: String
    /// nil is an empty/missing pattern; trailing spaces in a value are retained.
    public let pattern: String?
    public let formats: [BibleCopyFormat]
    public let sourceXML: XMLNode
}

public struct BibleCopyStyle: Identifiable, Codable, Hashable, Sendable {
    public let identity: MetadataIdentity
    public let options: [String: String]
    public let templates: [BibleCopyTemplate]
    public let languages: [String: String]
    public let sourceXML: XMLNode
    public var id: String { identity.id }
    public var name: String { identity.name }
    public var title: String { identity.displayTitle }
}

public struct MetadataSnapshot: Codable, Sendable {
    public let root: URL
    public let associations: [ResourceAssociation]
    public let collections: [ResourceCollection]
    public let palettes: [VisualMarkupPalette]
    public let copyStyles: [BibleCopyStyle]
    public let opaqueFileCount: Int
    public let warnings: [String]
    public var parsedDocumentCount: Int { associations.count + collections.count + palettes.count + copyStyles.count }
}
