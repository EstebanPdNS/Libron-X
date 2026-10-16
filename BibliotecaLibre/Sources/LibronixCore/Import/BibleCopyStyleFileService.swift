#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Bounded style I/O belongs to this actor. The caller owns the security scope
/// and the destination choice; original library roots remain read-only.
public actor BibleCopyStyleFileService {
    public init() {}

    public func read(_ url: URL) throws -> BibleCopyOutputStyle {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: MetadataXMLReader.maximumFileBytes + 1) ?? Data()
        guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        try Task.checkCancellation()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var style = try BibleCopyOutputStyle.importing(data, sourceSHA256: hash)
        style.id = UUID(); style.preset = nil
        try Task.checkCancellation()
        return style
    }

    public func write(_ style: BibleCopyOutputStyle, to url: URL, protecting roots: [URL]) throws {
        try Task.checkCancellation()
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        for root in roots {
            let protected = root.resolvingSymlinksInPath().standardizedFileURL
            guard target.path != protected.path,
                  !target.path.hasPrefix(protected.path.hasSuffix("/") ? protected.path : protected.path + "/") else {
                throw PersonalStateError.invalid("Guarda el estilo en otra carpeta; la biblioteca original se conserva sin cambios.")
            }
        }
        let data = try style.exportedXML()
        try Task.checkCancellation()
        // Once this atomic replacement begins it finishes. Cancellation must
        // never report that an already committed export was rolled back.
        try data.write(to: url, options: .atomic)
    }
}
