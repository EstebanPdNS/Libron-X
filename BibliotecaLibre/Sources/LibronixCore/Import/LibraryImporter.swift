import Foundation

public enum LibraryImportError: Error, LocalizedError, Sendable {
    case notDirectory, enumerationFailed, tooManyFiles
    public var errorDescription: String? {
        switch self {
        case .notDirectory: "Selecciona una carpeta que contenga los recursos de tu biblioteca."
        case .enumerationFailed: "No se pudo leer la carpeta seleccionada. Comprueba sus permisos."
        case .tooManyFiles: "La carpeta excede el límite de 100.000 archivos del importador."
        }
    }
}

/// Owns file enumeration and read-only metadata import on its own actor, away
/// from the main actor. Cancellation leaves the previous UI snapshot intact.
public actor LibraryImporter {
    public init() {}

    public func importDirectory(at root: URL,
        progress: (@Sendable (ImportProgress) async -> Void)? = nil) async throws -> LibrarySnapshot {
        let start = ContinuousClock.now
        let enumerated = try enumerate(at: root)
        let candidates = enumerated.candidates
        let legacyIndexes = enumerated.legacyIndexes
        var result: [LibraryResource] = []
        let helpStems: Set<String> = ["BECAOVB", "ELS_SPA", "GENSPUG", "GUIDESP", "UBSOVB", "UBSSHELP", "UBS_TIPS"]
        for (offset, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            let (url, size) = candidate
            let ext = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent
            let isHelp = stem.lowercased().hasPrefix("help-") || helpStems.contains(stem.uppercased())
            if ext == "libron" {
                result.append(try LibronPackage.read(url).1)
            } else if ESwordResource.extensions.contains(ext) {
                result.append(try ESwordResource.inspect(url))
            } else if ext == "epub" {
                let archive = try EPUBArchive(url), m = archive.metadata
                result.append(LibraryResource(location: url, title: m.title, author: m.authors.first, languages: m.languages,
                    byteCount: size, format: .epub, support: .metadataOnly, provenance: .libronixMetadata, libron: m))
            } else if ext.hasPrefix("logos") {
                result.append(LibraryResource(location: url, title: stem, byteCount: size,
                    format: ext == "epub" ? .epub : .logosModern, support: .opaqueContainer, provenance: .fileName))
            } else if ext == "lsf" {
                let index = legacyIndexes[pairKey(url)]
                do {
                    let inspected = try LegacyResourceReader.inspect(lsfURL: url, lixURL: index)
                    let metadata = inspected.lsf
                    result.append(LibraryResource(location: url, indexLocation: index,
                        title: metadata.title ?? metadata.marcTitle ?? stem, author: metadata.author,
                        languages: metadata.declaredLanguages, byteCount: size, format: .legacyLSF,
                        support: .metadataOnly, provenance: .legacyPublicMetadata,
                        legacyIdentifier: metadata.bkidHex, isHelp: isHelp, warnings: inspected.warnings))
                } catch {
                    result.append(LibraryResource(location: url, indexLocation: index, title: stem,
                        byteCount: size, format: .legacyLSF, support: .invalidFile,
                        provenance: .fileName, isHelp: isHelp, warnings: [String(describing: error)]))
                }
            } else {
                do {
                    let signature = try readSignature(at: url)
                    let isLTES = signature.count >= 8 && Array(signature.prefix(4)) == [0x4c, 0x54, 0x45, 0x53]
                    let book = isLTES ? try? LibronixBookArchive.inspect(at: url).metadata() : nil
                    result.append(LibraryResource(location: url, title: book?.title ?? stem, author: book?.author,
                        languages: book?.languages ?? [], byteCount: size,
                        format: ext == "lbxlls" ? .libronixLLS : .libronixOEB,
                        support: book != nil ? .metadataOnly : isLTES ? .opaqueContainer : .invalidFile,
                        provenance: book != nil ? .libronixMetadata : .fileName, legacyIdentifier: book?.identifier, isHelp: isHelp,
                        warnings: isLTES ? [] : ["Cabecera de recurso no reconocida."]))
                } catch {
                    result.append(LibraryResource(location: url, title: stem, byteCount: size,
                        format: ext == "lbxlls" ? .libronixLLS : .libronixOEB,
                        support: .invalidFile, provenance: .fileName, isHelp: isHelp,
                        warnings: ["No se pudo leer la cabecera del recurso."]))
                }
            }
            if offset % 20 == 0 || offset + 1 == candidates.count {
                await progress?(ImportProgress(completed: offset + 1, total: candidates.count))
            }
        }
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return LibrarySnapshot(root: root, resources: result, discoveredFiles: enumerated.discoveredFiles,
            importDurationSeconds: seconds)
    }

    /// Foundation's DirectoryEnumerator is synchronous. Keep its lifetime
    /// entirely within this actor-isolated synchronous boundary.
    private func enumerate(at root: URL) throws -> (candidates: [(URL, Int64)], legacyIndexes: [String: URL], discoveredFiles: Int) {
        let manager = FileManager()
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw LibraryImportError.notDirectory
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let iterator = ResourceDirectoryEnumerator(root: root, keys: Array(keys)) else {
            throw LibraryImportError.enumerationFailed
        }
        var candidates: [(URL, Int64)] = []
        var legacyIndexes: [String: URL] = [:]
        var discoveredFiles = 0
        while let url = try iterator.nextURL() {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { iterator.skipDescendants(); continue }
            let ext = url.pathExtension.lowercased()
            if values.isDirectory == true {
                if url.lastPathComponent.lowercased() == "backup" { iterator.skipDescendants(); continue }
                if ext == "libron" { candidates.append((url, 0)); discoveredFiles += 1; iterator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, LibronPackage.sourceExtensions.union(["lix"]).contains(ext) else { continue }
            discoveredFiles += 1
            guard discoveredFiles <= 100_000 else { throw LibraryImportError.tooManyFiles }
            if ext == "lix" {
                legacyIndexes[pairKey(url)] = url
            } else {
                candidates.append((url, Int64(values.fileSize ?? 0)))
            }
        }
        candidates.sort { $0.0.path < $1.0.path }
        return (candidates, legacyIndexes, discoveredFiles)
    }

    private func pairKey(_ url: URL) -> String {
        url.deletingPathExtension().standardizedFileURL.path.lowercased()
    }

    private func readSignature(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 16) ?? Data()
    }
}
