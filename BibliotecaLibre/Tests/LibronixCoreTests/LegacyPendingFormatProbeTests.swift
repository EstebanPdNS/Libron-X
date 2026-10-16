import Foundation
import Testing
@testable import LibronixCore

/// Opt-in, private source payload evidence. No original is modified.
struct LegacyPendingFormatProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_PENDING_FORMAT_CORPUS"] != nil))
    func capturePendingSourceFrames() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_PENDING_FORMAT_CORPUS"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_PENDING_FORMAT_RECEIPT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let books = LibronixBookService()
        for (name, ordinals) in [("HBS.lbxlls", [1693]), ("RVR60NTRI.lbxlls", [1,153]), ("RVR60OTRI.lbxlls", [1,493])] {
            let url = root.appendingPathComponent(name), stamp = try LegacyGraphicsService.fileStamp(url)
            let archive = try LibronixBookArchive.inspect(at: url), metadata = try archive.metadata()
            let resource = LibraryResource(location: url, title: metadata.title ?? name, byteCount: Int64(stamp.size),
                format: .libronixLLS, support: .metadataOnly, provenance: .libronixMetadata, legacyIdentifier: metadata.identifier)
            let inner = try await books.prepare(resource)
            let styles = try LegacyTypographyReader.inspect(lsfURL: inner.location)
            try JSONEncoder().encode(styles).write(to: output.appendingPathComponent(name + ".styles.json"))
            try archive.readEntry("this.metadata.xml").write(to: output.appendingPathComponent(name + ".metadata.xml"))
            for ordinal in ordinals {
                let payload = try LegacyContentReader.decodedSectionPayload(lsfURL: inner.location, ordinal: ordinal)
                try payload.write(to: output.appendingPathComponent(name + "." + String(ordinal) + ".bin"))
                print("Pending source payload: \(name)[\(ordinal)]; bytes=\(payload.count)")
                let content = try LegacyContentReader.readSection(lsfURL: inner.location, ordinal: ordinal)
                let encoded = try JSONEncoder().encode(content)
                try encoded.write(to: output.appendingPathComponent(name + "." + String(ordinal) + ".decoded.json"))
                print("Decoded source frame: \(name)[\(ordinal)]; UTF16=\(content.plainText.utf16.count); units=\(content.interlinears?.count ?? 0); sourceExtent=\(content.expectedCharacterCount)")
                if name != "HBS.lbxlls", ordinal > 100 {
                    #expect(!(content.interlinears ?? []).isEmpty)
                    #expect(content.hasCompatibleFlatTextProjection)
                }

            }
            #expect(try LegacyGraphicsService.fileStamp(url) == stamp)
        }
    }
}
