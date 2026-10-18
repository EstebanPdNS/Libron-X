import Foundation
import CryptoKit
import LibronixCore

struct ImportedResourceAssociation: Codable, Equatable, Sendable {
    let sourceURL: URL
    let sourceBytes: Data
    let sha256: String
    let groupIndex: Int
    let definitionID: String
    let definitionTitle: String
    let group: ResourceAssociationGroup
    var identity: String { sha256 + ":" + String(groupIndex) }
    init(document: ResourceAssociationDocument, groupIndex: Int) {
        sourceURL = document.source; sourceBytes = document.data
        sha256 = Self.digest(document.data); self.groupIndex = groupIndex
        definitionID = document.definition.id; definitionTitle = document.definition.title
        group = document.definition.groups[groupIndex]
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    var prefix: String { "/.libronx-association/" + sha256 + "/" + String(groupIndex) + "/" }
    func memberID(_ index: Int) -> String { prefix + String(index) }
    func guid(for member: LibraryCollectionMember) -> String? {
        guard member.id.hasPrefix(prefix), let index = Int(member.id.dropFirst(prefix.count)),
              group.resourceIDs.indices.contains(index), member.id == memberID(index),
              member.format == .libronixLLS, member.legacyIdentifier == group.resourceIDs[index] else { return nil }
        return group.resourceIDs[index]
    }
    func validate() throws {
        guard sourceURL.isFileURL, sourceURL.path.utf8.count <= 16_384,
              !sourceURL.path.contains("\0"), Self.digest(sourceBytes) == sha256 else { throw LegacyIndicesError.sourceChanged }
        let document = try MetadataImporter.associationDocument(data:sourceBytes,source:sourceURL)
        guard document.definition.groups.indices.contains(groupIndex), document.definition.id == definitionID,
              document.definition.title == definitionTitle, document.definition.groups[groupIndex] == group else {
            throw LegacyIndicesError.sourceChanged
        }
    }
    static func isReserved(_ member: LibraryCollectionMember) -> Bool { member.id.hasPrefix("/.libronx-association/") }
    static func identifiers(_ resource: LibraryResource) -> Set<String> {
        var values = resource.legacyIdentifier.map { [$0] } ?? []
        if let data = resource.libron?.originalInformation?.data(using:.utf8),
           let root = try? JSONDecoder().decode(XMLNode.self,from:data),
           let metadata = root.name == "metadata" ? root : root.child(named:"metadata") {
            values += metadata.children.filter { $0.name == "commerce-id" || $0.name == "alternate-id" }.compactMap { $0.attributes["guid"] }
        }
        return Set(values.map { $0.lowercased() })
    }
}

/// Build once per catalog revision, not once per imported member or SwiftUI row.
struct ResourceAssociationCatalog: Sendable {
    let resources: [LibraryResource]
    let legacyIDs: [String: [LibraryResource]]
    init(resources: [LibraryResource]) {
        self.resources = resources
        var map: [String: [LibraryResource]] = [:]
        for resource in resources {
            for id in ImportedResourceAssociation.identifiers(resource) { map[id, default: []].append(resource) }
        }
        legacyIDs = map.mapValues { $0.sorted { $0.id < $1.id } }
    }
}
