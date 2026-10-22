import Foundation
import LibronixCore

struct ResourceCollectionFile: Codable, Sendable {
    let path: String
    let sha256: String
    let object: String
    let encryptedSHA256: String
    let downloadBytes: Int64
    let bytes: Int64
    let codec: String
    var url: URL? = nil

    func validate() throws {
        guard DownloadResourceEntry.safe(path), path.utf8.count < 1_024,
              DownloadResourceEntry.safe(object), object.hasPrefix("objects/"),
              Self.hash(sha256), Self.hash(encryptedSHA256), codec == "zlib",
              bytes >= 0, bytes <= 2_147_483_648, downloadBytes >= 28, downloadBytes <= 2_147_483_648,
              url.map(Self.https) ?? true else { throw LibronError.invalid("Invalid resource file") }
    }
    static func hash(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func https(_ url: URL) -> Bool { url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil }
}
struct ResourceOriginalFile: Codable, Sendable {
    let path: String
    let sha256: String
}
struct ResourceCollectionEntry: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let packageName: String
    let hidden: Bool
    let files: [ResourceCollectionFile]
    var compatibleOriginalFiles: [ResourceOriginalFile]? = nil
    func validate() throws {
        guard !id.isEmpty, id.utf8.count < 16_384, !id.contains("\0"), !title.isEmpty, title.utf8.count <= 4_096,
              DownloadResourceEntry.safe(packageName), !packageName.contains("/"), packageName.hasSuffix(".libron"), packageName.utf8.count <= 255,
              !files.isEmpty, files.count <= 10_000, Set(files.map(\.path)).count == files.count,
              files.contains(where: { $0.path == "manifest.json" }), files.reduce(Int64(0), { $0 + $1.bytes }) <= 16_000_000_000 else {
            throw LibronError.invalid("Invalid resource collection entry")
        }
        for file in files { try file.validate() }
        if let originals = compatibleOriginalFiles {
            guard originals.count == files.count, Set(originals.map(\.path)) == Set(files.map(\.path)),
                  originals.allSatisfy({ ResourceCollectionFile.hash($0.sha256) }) else { throw LibronError.invalid("Invalid original resource signatures") }
        }
    }
    func matches(_ package: URL) throws -> Bool {
        guard let resource = try? LibronPackage.read(package).1, resource.id == id else { return false }
        func matches(_ members: [(String, String)]) throws -> Bool {
            for (path, hash) in members {
                try Task.checkCancellation()
                let url = try ResourceDownloadPaths.member(path, under: package)
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      (try? LibronPackage.hash(url)) == hash else { return false }
            }
            return true
        }
        if try matches(files.map { ($0.path, $0.sha256) }) { return true }
        return try compatibleOriginalFiles.map { try matches($0.map { ($0.path, $0.sha256) }) } ?? false
    }
}
struct ResourceCollectionManifest: Codable, Sendable {
    let format: String
    let schemaVersion: Int
    let id: String
    let title: String
    let resources: [ResourceCollectionEntry]
    var readingFonts: [ResourceCollectionFile]? = nil
    var baseURL: URL? = nil
    func validate() throws {
        guard format == "org.libron.download.collection", schemaVersion == 2, !id.isEmpty, !title.isEmpty,
              !resources.isEmpty, resources.count <= 50_000, Set(resources.map(\.id)).count == resources.count,
              Set(resources.map { $0.packageName.precomposedStringWithCanonicalMapping.lowercased() }).count == resources.count,
              baseURL.map(ResourceCollectionFile.https) ?? true, (readingFonts?.count ?? 0) <= 128 else { throw LibronError.invalid("Invalid resource collection") }
        for entry in resources { try entry.validate() }
        for font in readingFonts ?? [] {
            try font.validate()
            guard !font.path.contains("/"), ["ttf", "otf"].contains(URL(fileURLWithPath: font.path).pathExtension.lowercased()), font.bytes < 16 * 1_024 * 1_024 else { throw LibronError.invalid("Invalid reading font") }
        }
    }
    func downloadURL(for file: ResourceCollectionFile, manifestURL: URL) throws -> URL {
        let result = file.url ?? URL(string: file.object, relativeTo: baseURL ?? manifestURL.deletingLastPathComponent())!.absoluteURL
        guard ResourceCollectionFile.https(result) else { throw LibronError.invalid("Invalid resource URL") }
        return result
    }
}
enum ResourceDownloadPaths {
    static func member(_ path: String, under root: URL) throws -> URL {
        guard DownloadResourceEntry.safe(path) else { throw LibronError.invalid("Unsafe resource path") }
        let root = root.standardizedFileURL
        var next = root
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LibronError.invalid("Symbolic link in resource destination") }
        for component in path.split(separator: "/") {
            next.appendPathComponent(String(component))
            guard (try? next.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LibronError.invalid("Symbolic link in resource destination") }
        }
        guard next.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw LibronError.invalid("Resource path leaves library") }
        return next
    }
}
