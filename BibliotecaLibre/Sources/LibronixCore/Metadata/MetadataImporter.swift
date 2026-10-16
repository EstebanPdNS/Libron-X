import Foundation

/// Imports declarative metadata only. Books (lbxlls/lbxoeb), license backups
/// (lbxlbk), executables and scripts are excluded from this inspection.
public struct MetadataImporter: Sendable {
    public init() {}

    public func inspectDirectory(at root: URL) throws -> MetadataSnapshot {
        try Self.inspectDirectory(at: root)
    }

    public static func inspectDirectory(at root: URL) throws -> MetadataSnapshot {
        let manager = FileManager()
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw MetadataReadError.notDirectory
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let iterator = ResourceDirectoryEnumerator(root: root, keys: keys) else {
            throw MetadataReadError.notDirectory
        }
        let extensions: Set<String> = ["lbxadd", "lbxshl", "lbxdtp", "lbxcit", "lbxcmp",
            "lbxcol", "lbxlct", "lbxplp", "lbxdat", "lbxrlr", "lbxrls", "lbxsan",
            "lbxtml", "lbxvmp", "lbxlml", "lbxlty", "lbxppl", "lbxper", "lbxras",
            "lbxrtp", "lbxcbv", "lbxupd"]
        var files: [URL] = []
        while let url = try iterator.nextURL() {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
            guard files.count <= 100_000 else { throw MetadataReadError.tooManyFiles }
        }
        files.sort { $0.path < $1.path }
        var associations: [ResourceAssociation] = []
        var collections: [ResourceCollection] = []
        var palettes: [VisualMarkupPalette] = []
        var copyStyles: [BibleCopyStyle] = []
        var opaqueFileCount = 0
        var warnings: [String] = []
        for url in files {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let prefix = try handle.read(upToCount: 4) ?? Data()
                if prefix.starts(with: [0x4c, 0x54, 0x45, 0x53]) {
                    opaqueFileCount += 1
                    continue
                }
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= MetadataXMLReader.maximumFileBytes else { throw MetadataReadError.fileTooLarge }
                try handle.seek(toOffset: 0)
                let data = try handle.read(upToCount: MetadataXMLReader.maximumFileBytes + 1) ?? Data()
                let node = try MetadataXMLReader.parse(data)
                let identity = identity(for: node, source: url)
                switch node.name {
                case "lbx-resource-association":
                    associations.append(association(node, identity))
                case "lbx-resource-collection":
                    collections.append(collection(node, identity))
                case "lbx-visual-markup-palette":
                    palettes.append(palette(node, identity))
                case "lbx-copy-bible-verses-style":
                    copyStyles.append(copyStyle(node, identity))
                default: throw MetadataReadError.unsupportedDocument(node.name)
                }
            } catch {
                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return MetadataSnapshot(root: root, associations: associations, collections: collections,
            palettes: palettes, copyStyles: copyStyles, opaqueFileCount: opaqueFileCount, warnings: warnings)
    }

    private static func identity(for node: XMLNode, source: URL) -> MetadataIdentity {
        let name = node.attributes["name"] ?? source.deletingPathExtension().lastPathComponent
        let category = node.attributes["category"]
        let titles = localizedValues(node.child(named: "header"), element: "title")
        let fallbackTitles = localizedValues(node.child(named: "metadata"), element: "title")
        return MetadataIdentity(id: "\(category ?? node.name):\(name)", name: name,
            category: category, guid: node.attributes["guid"], version: node.attributes["version"],
            creator: node.attributes["creator"], owner: node.attributes["owner"], source: source,
            titles: fallbackTitles.merging(titles) { _, header in header },
            descriptions: localizedValues(node.child(named: "header"), element: "desc"),
            attributes: node.attributes)
    }

    private static func localizedValues(_ node: XMLNode?, element: String) -> [String: String] {
        var values: [String: String] = [:]
        for child in node?.children(named: element) ?? [] {
            values[child.attributes["xml:lang"] ?? ""] = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    private static func association(_ node: XMLNode, _ identity: MetadataIdentity) -> ResourceAssociation {
        let groups = node.children(named: "association").map { group in
            ResourceAssociationGroup(guid: group.attributes["guid"],
                priority: group.attributes["priority"].flatMap(Int.init),
                priorityText: group.attributes["priority"], type: group.attributes["type"],
                resourceIDs: group.children(named: "resource").compactMap { $0.attributes["guid"] },
                attributes: group.attributes)
        }
        let obsolete = node.comments.contains { $0.lowercased().contains("obsolete") }
        return ResourceAssociation(identity: identity, groups: groups,
            definitionState: groups.isEmpty ? (obsolete ? .obsoletePlaceholder : .emptyDefinition) : .declaredGroups,
            sourceXML: node)
    }

    private static func collection(_ node: XMLNode, _ identity: MetadataIdentity) -> ResourceCollection {
        let wrapper = node.child(named: "resource-filter")
        let filter: ResourceFilter?
        if let wrapper {
            filter = wrapper.children.count == 1 ? parseFilter(wrapper.children[0]) : .unknown(wrapper)
        } else { filter = nil }
        let commerceIDs = node.child(named: "metadata")?.children(named: "collection-commerce-id")
            .compactMap { $0.attributes["guid"] } ?? []
        return ResourceCollection(identity: identity, filter: filter, commerceIDs: commerceIDs, sourceXML: node)
    }

    private static func parseFilter(_ node: XMLNode) -> ResourceFilter {
        switch node.name {
        case "resource":
            if let id = node.attributes["resource-id"] { return .resource(id: id) }
        case "or": return .any(node.children.map(parseFilter))
        case "and": return .all(node.children.map(parseFilter))
        case "not":
            if node.children.count == 1 { return .not(parseFilter(node.children[0])) }
        default: break
        }
        return .unknown(node)
    }

    private static func palette(_ node: XMLNode, _ identity: MetadataIdentity) -> VisualMarkupPalette {
        let styles: [VisualMarkupStyle] = node.child(named: "palette-styles")?.children(named: "palette-style").map { style in
            VisualMarkupStyle(name: style.attributes["name"] ?? "", version: style.attributes["version"],
                titles: localizedValues(style, element: "title"), attributes: style.attributes,
                markup: style.child(named: "markup-style"), sourceXML: style)
        } ?? []
        return VisualMarkupPalette(identity: identity, styles: styles, sourceXML: node)
    }

    private static func copyStyle(_ node: XMLNode, _ identity: MetadataIdentity) -> BibleCopyStyle {
        var options: [String: String] = [:]
        for option in node.child(named: "options")?.children(named: "option") ?? [] {
            if let name = option.attributes["name"] { options[name] = option.text }
        }
        let templates: [BibleCopyTemplate] = node.child(named: "templates")?.children(named: "template").map { template in
            let pattern = template.child(named: "pattern")
            let formats = template.children(named: "format").map {
                BibleCopyFormat(name: $0.attributes["name"] ?? "", value: $0.content.isEmpty ? nil : $0.text,
                    attributes: $0.attributes)
            }
            return BibleCopyTemplate(name: template.attributes["name"] ?? "",
                pattern: pattern.flatMap { $0.content.isEmpty ? nil : $0.text },
                formats: formats, sourceXML: template)
        } ?? []
        var languages: [String: String] = [:]
        for language in node.child(named: "languages")?.children(named: "language") ?? [] {
            if let name = language.attributes["name"] { languages[name] = language.text }
        }
        return BibleCopyStyle(identity: identity, options: options, templates: templates,
            languages: languages, sourceXML: node)
    }
}
