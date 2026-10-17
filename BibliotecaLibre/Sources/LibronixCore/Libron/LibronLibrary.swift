import Foundation

public actor LibronLibrary {
    public init() {}
    public func convert(_ sources: [URL], to destination: URL, backup: Bool,
                        progress: (@Sendable (ImportProgress) async -> Void)? = nil) async throws -> [LibraryResource] {
        var incoming: [LibraryResource] = []
        let importer = LibraryImporter()
        for source in sources {
            var directory: ObjCBool = false
            if source.pathExtension.lowercased() == "libron" { incoming.append(try LibronPackage.read(source, verify: true).1) }
            else if FileManager.default.fileExists(atPath: source.path, isDirectory: &directory), directory.boolValue {
                incoming += try await importer.importDirectory(at: source).resources
            } else {
                // Reuse the boundary scanner in an isolated staging directory.
                let stage = FileManager.default.temporaryDirectory.appendingPathComponent("libron-scan-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                do {
                    try FileManager.default.copyItem(at: source, to: stage.appendingPathComponent(source.lastPathComponent))
                    if source.pathExtension.lowercased() == "lsf" {
                        let parent = source.deletingLastPathComponent()
                        if let companion = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).first(where: {
                            $0.pathExtension.lowercased() == "lix" && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(source.deletingPathExtension().lastPathComponent) == .orderedSame
                        }) { try FileManager.default.copyItem(at: companion, to: stage.appendingPathComponent(companion.lastPathComponent)) }
                    }
                    let scanned = try await importer.importDirectory(at: stage).resources
                    for r in scanned {
                        incoming.append(LibraryResource(location: source, indexLocation: r.indexLocation.map { source.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent) }, title: r.title,
                            author: r.author, languages: r.languages, byteCount: r.byteCount, format: r.format, support: r.support,
                            provenance: r.provenance, legacyIdentifier: r.legacyIdentifier, isHelp: r.isHelp, warnings: r.warnings, libron: r.libron))
                    }
                    try FileManager.default.removeItem(at: stage)
                } catch { try? FileManager.default.removeItem(at: stage); throw error }
            }
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let current = try await importer.importDirectory(at: destination).resources
        var hashes = Set(try current.map { try LibronPackage.hash($0.location) })
        for (index, resource) in incoming.enumerated() {
            try Task.checkCancellation()
            guard resource.support != .invalidFile else { throw LibronError.invalid("Invalid resource: " + resource.fileName) }
            let hash = try LibronPackage.hash(resource.location)
            if hashes.insert(hash).inserted {
                try LibronPackage.create(resource, in: destination, backup: backup, metadata: LibronBibliography.enrich(resource))
            } else if backup { try LibronPackage.backupOriginal(resource, in: destination) }
            await progress?(.init(completed: index + 1, total: incoming.count))
        }
        let result = try await importer.importDirectory(at: destination).resources
        for resource in result where resource.format == .eSwordSQLite {
            if let package = resource.packageLocation,
               let data = try? Data(contentsOf:package.appendingPathComponent("import-formatting-audit.json")),
               let report = try? JSONDecoder().decode(ImportFormattingAudit.self,from:data),
               report.pipelineVersion == ImportFormattingPipeline.version { continue }
            let report = try ESwordResource.audit(resource.location)
            if let package = resource.packageLocation {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                try encoder.encode(report).write(to: package.appendingPathComponent("import-formatting-audit.json"), options: .atomic)
            }
        }
        for resource in result where LibronDictionaryIndex.supports(resource) {
            _ = try await LibronDictionaryIndexService.shared.index(resource)
        }
        try LibronCatalog(resources: result).save(to: destination)
        return result
    }
}
