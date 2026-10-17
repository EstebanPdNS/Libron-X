import Foundation
import LibronixCore

enum LibronInspection {
    static func run(_ args: [String]) async throws -> Data {
        guard args.count >= 3 else { throw LibronError.invalid("Usage: libronix-inspect libron catalog|convert DEST SOURCE... [--metadata FILE]") }
        let mode = args[0], destination = URL(fileURLWithPath: args[1])
        var paths = Array(args.dropFirst(2)), overrides: [String: LibronMetadata] = [:]
        if let flag = paths.firstIndex(of: "--metadata"), flag + 1 < paths.count {
            overrides = try JSONDecoder().decode([String: LibronMetadata].self, from: Data(contentsOf: URL(fileURLWithPath: paths[flag + 1])))
            paths.removeSubrange(flag...flag + 1)
        }
        var resources: [LibraryResource] = []
        for path in paths {
            let snapshot = try await LibraryImporter().importDirectory(at: URL(fileURLWithPath: path))
            resources += snapshot.resources
        }
        var seen = Set<String>(), entries: [LibraryResource] = [], failures: [String] = [], duplicates: [String] = []
        for resource in resources {
            do {
                let hash = try LibronPackage.hash(resource.location)
                if !seen.insert(hash).inserted { duplicates.append(resource.location.path); continue }
                let metadata = overrides[resource.location.lastPathComponent] ?? LibronBibliography.enrich(resource)
                if mode == "convert" {
                    let package = try LibronPackage.create(resource, in: destination, backup: true, metadata: metadata)
                    entries.append(try LibronPackage.read(package, verify: true).1)
                } else {
                    entries.append(LibraryResource(location: resource.location, indexLocation: resource.indexLocation, title: metadata.title,
                        author: metadata.authors.first, languages: metadata.languages, byteCount: resource.byteCount, format: resource.format,
                        support: resource.support, provenance: resource.provenance, legacyIdentifier: resource.legacyIdentifier,
                        isHelp: resource.isHelp, libron: metadata))
                }
            } catch { failures.append(resource.location.path + ": " + error.localizedDescription) }
        }
        struct Report: Encodable { var resources: [LibraryResource]; var failures: [String]; var duplicates: [String] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let data = try encoder.encode(Report(resources: entries, failures: failures, duplicates: duplicates))
        if mode == "convert" { try LibronCatalog(resources: entries).save(to: destination) }
        if mode == "convert" { try data.write(to: destination.appendingPathComponent("migration-report.json"), options: .atomic) }
        return data
    }
}
