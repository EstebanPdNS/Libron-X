import Foundation

/// A declaration in the original resource metadata, not evidence that its
/// topic keys or article associations have been decoded. Preserve named indexes
/// (for example city/water) and language order rather than merging them with
/// the default topics index or with article titles.
public struct LibronixTopicIndexDeclaration: Sendable, Equatable, Codable {
    public let name: String
    public let languages: [String]

    public static func read(from document: XMLNode) -> [Self] {
        let indexes = document.child(named: "metadata")?.child(named: "indexes")?.children(named: "index") ?? []
        return indexes.compactMap { index in
            guard index.attributes["type"] == "topic", let name = index.attributes["name"], !name.isEmpty else { return nil }
            return Self(name: name, languages: index.children(named: "language").compactMap {
                guard let name = $0.attributes["name"], !name.isEmpty else { return nil }
                return name
            })
        }
    }
}

extension LibronixBookMetadata {
    public var declaredTopicIndexes: [LibronixTopicIndexDeclaration] {
        LibronixTopicIndexDeclaration.read(from: xml)
    }
}
