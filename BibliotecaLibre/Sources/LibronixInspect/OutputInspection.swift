import Foundation
import LibronixCore
#if canImport(LibronixOutputMac)
import LibronixOutputMac
#endif

enum OutputInspection {
    static func typography(_ path: String) throws -> Data {
        let source = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw LegacyTypographyError.missingTable }
        let files = isDirectory.boolValue ? try directoryFiles(at: source)
            .filter { $0.pathExtension.caseInsensitiveCompare("LSF") == .orderedSame }.sorted { $0.lastPathComponent < $1.lastPathComponent } : [source]
        var results: [[String: Any]] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for file in files {
            let before = try LegacyGraphicsService.fileStamp(file), value = try LegacyTypographyReader.inspect(lsfURL: file)
            guard try LegacyGraphicsService.fileStamp(file) == before else { throw LegacyIndicesError.sourceChanged }
            let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
            results.append(["file":file.lastPathComponent,"typography":object,"sourceVerifiedAfter":true])
        }
        return try JSONSerialization.data(withJSONObject: ["resources":results,"generalRenderingParityVerified":false], options:[.prettyPrinted,.sortedKeys])
    }
    private static func directoryFiles(at source: URL) throws -> [URL] {
#if os(Windows)
        // Foundation's URL listing can silently return no entries for UNC paths.
        return try FileManager.default.contentsOfDirectory(atPath: source.path)
            .map { source.appendingPathComponent($0) }
#else
        return try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
#endif
    }
    @MainActor static func run(_ args: [String]) async throws -> Data {
#if canImport(LibronixOutputMac)
        guard args.count == 3 || args.count == 5, let ordinal = Int(args[1]), ordinal >= 0 else { throw ReaderOutputError.invalidSelection }
        let file = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[2], isDirectory: true)
        let metadata = try LegacyResourceReader.inspect(lsfURL: file).lsf
        let resource = LibraryResource(location: file, title: metadata.title ?? "Recurso", byteCount: Int64(try LegacyGraphicsService.fileStamp(file).size),
            format: .legacyLSF, support: .metadataOnly, provenance: .legacyPublicMetadata, legacyIdentifier: metadata.bkidHex)
        let content = try LegacyContentReader.readSection(lsfURL: file, ordinal: ordinal)
        let request: ReaderOutputRequest
        if args.count == 5 {
            guard let location = Int(args[3]), let length = Int(args[4]) else { throw ReaderOutputError.invalidSelection }
            request = .selection(.init(location: location, length: length))
        } else { request = .reading }
        let document = try await ReaderOutputService().prepare(resource, sectionOrdinal: ordinal,
            expectedTextFingerprint: LibrarySearchService.textFingerprint(content.plainText), request: request)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let plain = ReaderOutputEncoder.text(document), html = try ReaderOutputEncoder.html(document)
        try plain.write(to: output.appendingPathComponent("reader-output.txt"), options: .atomic)
        try html.write(to: output.appendingPathComponent("reader-output.html"), options: .atomic)
        let pdf = try NativeReaderOutput.pdf(document), rtf = try NativeReaderOutput.rtf(document)
        try pdf.write(to: output.appendingPathComponent("reader-output.pdf"), options: .atomic)
        try rtf.write(to: output.appendingPathComponent("reader-output.rtf"), options: .atomic)
        let report: [String: Any] = ["scope":document.scope.rawValue,"sourceSections":document.sources.map(\.sectionOrdinal),
            "referenceCount":document.references.count,"paragraphs":document.paragraphs.count,"characters":document.plainText.utf16.count,
            "plainTextSHA256":LibrarySearchService.textFingerprint(String(decoding:plain,as:UTF8.self)),
            "htmlSHA256":LibrarySearchService.textFingerprint(String(decoding:html,as:UTF8.self)),
            "sourceFingerprints":document.sources.map(\.decodedTextSHA256),"citationIncludedInTXTOrHTML":false,
            "originalPhysicalFileSelectionVerified":false,"generalParityVerified":false]
        return try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys])
#else
        throw NativeOutputUnavailable()
#endif
    }

    private struct NativeOutputUnavailable: Error, LocalizedError {
        var errorDescription: String? {
            "Native PDF/RTF reader output requires macOS. No output files were created."
        }
    }
}
