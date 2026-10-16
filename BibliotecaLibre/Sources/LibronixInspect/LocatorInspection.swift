import Foundation
import LibronixCore

enum LocatorInspection {
    static func run(_ arguments: [String]) async throws -> Data {
        guard arguments.count == 3 || arguments.count == 5 else { throw LegacyLocatorError.invalidSyntax }
        let url = URL(fileURLWithPath: arguments[0]), lix = url.deletingPathExtension().appendingPathExtension("LIX")
        let pair = try LegacyResourceReader.inspect(lsfURL: url, lixURL: lix)
        let size = try LegacyGraphicsService.fileStamp(url).size
        let resource = LibraryResource(location: url, indexLocation: lix, title: "Diagnóstico de posición", byteCount: Int64(size),
            format: .legacyLSF, support: .metadataOnly, provenance: .legacyPublicMetadata, legacyIdentifier: pair.lsf.bkidHex)
        var context: [String: String] = [:]
        if arguments.count == 5 {
            let file = URL(fileURLWithPath: arguments[3])
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
            let document = try StudyDocument.importingLegacyXML(Data(contentsOf: file))
            guard let note = document.notes.first(where: { $0.sourceAttributes["guid"] == arguments[4] }),
                  note.sourceAttributes["resource-id"] == arguments[1], let special = note.sourceAttributes["special"] else { throw LegacyLocatorError.resourceMismatch }
            context = LegacyLocatorResolution.contextFields(special)
            guard context["pos"] == arguments[2] else { throw LegacyLocatorError.contextMismatch }
        }
        let service = LegacyContentService()
        let result = try await service.resolveArticleLocator(resource, originalResourceID: arguments[1], position: arguments[2])
        let content = try await service.read(url, ordinal: result.location.sectionOrdinal)
        guard LibrarySearchService.textFingerprint(content.plainText) == result.location.textFingerprint else { throw LegacyIndicesError.sourceChanged }
        let selected = (content.plainText as NSString).substring(with: result.range.nsRange)
        let contextChecks = LegacyLocatorResolution.contextChecks(context, text: content.plainText, range: result.range)
        var hintDifferences: [[String: Any]] = []
        for key in ["start-hint", "end-hint"] {
            if let raw = context[key], let hint = raw.removingPercentEncoding {
                let start = key == "start-hint" ? result.range.upperBound - hint.utf16.count : result.range.location
                if start >= 0, start + hint.utf16.count <= content.plainText.utf16.count {
                    let actual = Array((content.plainText as NSString).substring(with: NSRange(location: start, length: hint.utf16.count)).utf16)
                    for (i, expected) in hint.utf16.enumerated() where actual[i] != expected {
                        hintDifferences.append(["hint":key,"offset":start+i,"expectedUnit":Int(expected),"actualUnit":Int(actual[i])])
                    }
                }
            }
        }
        let report: [String: Any] = ["schemaVersion":1,"originalResourceID":arguments[1],"position":arguments[2],
            "sectionOrdinal":result.location.sectionOrdinal,"range":["location":result.range.location,"length":result.range.length],
            "sourceCharacterCount":result.sourceCharacterCount,"projectedUTF16Count":content.plainText.utf16.count,
            "decodedTextSHA256":result.location.textFingerprint ?? "","selectedTextSHA256":LibrarySearchService.textFingerprint(selected),
            "contextChecked":!context.isEmpty,"contextChecks":contextChecks,"contextMatches":contextChecks.values.allSatisfy({ $0 }),
            "hintDifferences":hintDifferences,"sourceSoftBreakOffsets":content.runs.filter(\.hasLeadingSoftBreak).map(\.characterOffset),
            "originalPhysicalFileSelectionProved":false,"generalParityVerified":false]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
    }
}
