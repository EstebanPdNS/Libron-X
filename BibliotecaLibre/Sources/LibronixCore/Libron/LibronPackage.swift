import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum LibronError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public struct LibronMember: Codable, Hashable, Sendable {
    public var path: String
    public var sha256: String
    public var byteCount: Int64
}
public struct LibronManifest: Codable, Hashable, Sendable {
    public var format = "org.libron.resource"
    public var schemaVersion = 1
    public var id: String
    public var metadata: LibronMetadata
    public var originalName: String
    public var sourceFormat: ResourceFormat
    public var legacyIdentifier: String?
    public var isHelp: Bool
    public var support: ResourceSupport
    public var payload: LibronMember
    public var index: LibronMember?
}
/// A .libron is an atomic macOS document package, not a renamed source file.
/// v1 retains an immutable native payload and optional companion index, so
/// existing lossless readers preserve layout, notes and source coordinates.
public enum LibronPackage {
    public static let sourceExtensions: Set<String> = ["lsf", "lbxlls", "lbxoeb", "logos4", "logos5", "logos6", "epub", "refi", "dcti", "bblx", "bbli", "lexi", "cmti"]
    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func filename(_ metadata: LibronMetadata, hash: String) -> String {
        func clean(_ value: String) -> String {
            let scalars = value.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> String in
                CharacterSet.controlCharacters.contains(scalar) || "/\\:*?\"<>|".unicodeScalars.contains(scalar) ? " " : String(scalar)
            }.joined()
            return scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        let parts = [metadata.title, metadata.authors.first, metadata.languages.first, metadata.year].compactMap { $0 }.map(clean).filter { !$0.isEmpty }
        // Byte-bounded names remain below common filesystem component limits.
        var name = parts.joined(separator: " — ")
        while name.utf8.count > 205 { name.removeLast() }
        return (name.isEmpty ? "Resource" : name) + " — " + hash.prefix(16) + ".libron"
    }
    public static func read(_ package: URL, verify: Bool = false) throws -> (LibronManifest, LibraryResource) {
        let manifestURL = package.appendingPathComponent("manifest.json")
        let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) < 4 * 1024 * 1024 else { throw LibronError.invalid("Manifest exceeds size limit") }
        let m = try JSONDecoder().decode(LibronManifest.self, from: Data(contentsOf: manifestURL))
        guard m.format == "org.libron.resource", m.schemaVersion == 1, !m.id.isEmpty, !m.metadata.title.isEmpty else { throw LibronError.invalid("Unsupported .libron manifest") }
        func member(_ value: LibronMember) throws -> URL {
            guard !value.path.hasPrefix("/"), !value.path.contains("\\"), !value.path.contains(":"), value.path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }) else { throw LibronError.invalid("Invalid package member") }
            let url = package.appendingPathComponent(value.path)
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(package.resolvingSymlinksInPath().path + "/"),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(value.byteCount) else { throw LibronError.invalid("Missing or changed package member") }
            if verify, try hash(url) != value.sha256 { throw LibronError.invalid("Package checksum mismatch") }
            return url
        }
        let payload = try member(m.payload), index = try m.index.map(member)
        return (m, LibraryResource(location: payload, indexLocation: index, title: m.metadata.title,
            author: m.metadata.authors.isEmpty ? nil : m.metadata.authors.joined(separator: "; "), languages: m.metadata.languages,
            byteCount: m.payload.byteCount, format: m.sourceFormat, support: m.support, provenance: .libronixMetadata,
            legacyIdentifier: m.legacyIdentifier, isHelp: m.isHelp, libron: m.metadata, packageLocation: package, stableID: m.id))
    }
    public static func copySourceFonts(_ resource: LibraryResource, to library: URL) throws {
        let fm = FileManager.default
        let source = resource.location.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Setup/Fonts")
        guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        let fonts = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]).filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        guard fonts.count <= 128 else { throw LibronError.invalid("Source font limit exceeded") }
        let destination = library.appendingPathComponent("Setup/Fonts", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for font in fonts {
            let values = try font.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 16 * 1024 * 1024 else { continue }
            let target = destination.appendingPathComponent(font.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: font, to: target) }
            guard try hash(font) == hash(target) else { throw LibronError.invalid("Conflicting source font") }
        }
    }
    public static func backupOriginal(_ resource: LibraryResource, in library: URL) throws {
        let fm = FileManager.default, digest = try hash(resource.location)
        let folder = library.appendingPathComponent("backup/" + digest, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in [resource.location, resource.indexLocation].compactMap({ $0 }) {
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                guard try hash(destination) == hash(url) else { throw LibronError.invalid("Backup collision") }
            } else { try fm.copyItem(at: url, to: destination) }
            guard try hash(destination) == hash(url) else { throw LibronError.invalid("Backup verification failed") }
        }
    }
    @discardableResult public static func create(_ resource: LibraryResource, in library: URL, backup: Bool,
                                                  metadata: LibronMetadata? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try copySourceFonts(resource, to: library)
        let digest = try hash(resource.location), metadata = metadata ?? .deriving(resource)
        let target = library.appendingPathComponent(filename(metadata, hash: digest), isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            let existing = try read(target, verify: true).0
            guard existing.payload.sha256 == digest else { throw LibronError.invalid("Destination collision") }
            if backup { try backupOriginal(resource, in: library) }
            return target
        }
        let stage = library.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage.appendingPathComponent("content"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        func copy(_ url: URL, as path: String) throws -> LibronMember {
            let destination = stage.appendingPathComponent(path)
            try fm.copyItem(at: url, to: destination)
            let before = try hash(url), after = try hash(destination)
            guard before == after else { throw LibronError.invalid("Source changed during conversion") }
            return LibronMember(path: path, sha256: after, byteCount: Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        }
        let payload = try copy(resource.location, as: "content/" + resource.location.lastPathComponent)
        guard payload.sha256 == digest else { throw LibronError.invalid("Source changed during conversion") }
        let index = try resource.indexLocation.map { try copy($0, as: "content/" + $0.lastPathComponent) }
        let manifest = LibronManifest(id: resource.id, metadata: metadata, originalName: resource.location.lastPathComponent,
            sourceFormat: resource.format, legacyIdentifier: resource.legacyIdentifier, isHelp: resource.isHelp,
            support: resource.support, payload: payload, index: index)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try read(stage, verify: true)
        if backup { try backupOriginal(resource, in: library) }
        try Task.checkCancellation()
        try fm.moveItem(at: stage, to: target)
        return target
    }
}
