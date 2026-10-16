import Foundation
import LibronixCore

/// Metadata-only census used to distinguish actual topic indexes from article
/// titles and other typed-reference tables. Never exports topic/book text.
enum TopicInspection {
    static func run(_ path: String, files: Set<String>, decodeTrees: Bool = false, verifyDestinations: Bool = false) async throws -> Data {
        let imported = try await LibraryImporter().importDirectory(at: URL(fileURLWithPath: path))
        let selected = imported.resources.filter { files.isEmpty || files.contains($0.fileName) }
        guard files.isSubset(of: Set(selected.map(\.fileName))) else { throw LibronixBookError.entryNotFound }
        var records: [[String: Any]] = []
        for resource in selected {
            try Task.checkCancellation()
            let before = try LegacyGraphicsService.fileStamp(resource.location)
            var row: [String: Any] = ["file": resource.fileName, "format": resource.format.rawValue,
                "topicKeysAndNumericReferentsDecoded": false, "topicWorkflowAccepted": false]
            do {
                if resource.format == .libronixLLS {
                    let archive = try LibronixBookArchive.inspect(at: resource.location)
                    let metadata = try archive.metadata()
                    row["declaredIndexes"] = metadata.xml.child(named: "metadata")?.child(named: "indexes")?
                        .children(named: "index").map { index in
                            ["type": index.attributes["type"] ?? "", "name": index.attributes["name"] ?? "",
                             "languages": index.children(named: "language").compactMap { $0.attributes["name"] }.joined(separator: ",")]
                        } ?? []
                    row["archiveMembers"] = archive.entries.map { ["path": $0.path, "bytes": $0.length] as [String: Any] }
                    row["declaredTopicIndexes"] = metadata.declaredTopicIndexes.map { ["name": $0.name, "languages": $0.languages] as [String: Any] }
                    if decodeTrees, !metadata.declaredTopicIndexes.isEmpty {
                        if archive.entries.contains(where: { $0.path == "fullindex.dat" }) {
                            let indexes: [LibronixNamedTopicIndex]
                            if verifyDestinations {
                                guard let bound = try await LibronixTopicCatalogService.shared.catalog(resource) else { throw LibronixTopicIndexFailure.missingTopics }
                                indexes = bound.indexes
                                row["allTopicReferentsHaveCheckedPhysicalArticles"] = true
                            } else { indexes = try LibronixTopicIndexReader.read(archive.readEntry("fullindex.dat", maximumBytes: 32 * 1024 * 1024)) }
                            row["decodedTopicTrees"] = indexes.map { index in
                                ["name": index.name, "encoding": index.stringEncoding, "topics": index.topics.count,
                                 "referents": index.labelsByReferent.count] as [String: Any]
                            }
                            row["topicKeysAndNumericReferentsDecoded"] = true
                        } else { row["topicStorageNotYetSupported"] = true }
                    }
                } else if resource.format == .legacyLSF {
                    let pair = try LegacyResourceReader.inspect(lsfURL: resource.location, lixURL: resource.indexLocation)
                    row["indexTables"] = (pair.lix?.blocks ?? []).filter { ["STAX", "ATSX", "TIDX", "TSIX"].contains($0.tag) }
                        .map { ["tag": $0.tag, "offset": $0.offset, "bytes": $0.length] as [String: Any] }
                    row["pairIdentifiersMatch"] = pair.identifiersMatch ?? false
                } else { row["unsupportedForThisCensus"] = true }
            } catch is CancellationError { throw CancellationError() }
            catch { row["error"] = error.localizedDescription }
            guard try LegacyGraphicsService.fileStamp(resource.location) == before else { throw LibronixBookError.sourceChanged }
            row["sourceUnchanged"] = true; records.append(row)
        }
        return try JSONSerialization.data(withJSONObject: ["metadataOnly": !decodeTrees, "resources": records], options: [.prettyPrinted, .sortedKeys])
    }

}
