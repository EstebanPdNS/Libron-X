import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LibronixCore

enum DocumentInspection {
    static func run(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        let data = try Data(contentsOf: url)
        let document = try StudyDocument.importingLegacyXML(data, sourceSHA256: hash(data))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let roundTrip = try JSONDecoder().decode(StudyDocument.self, from: encoder.encode(document))
        let notes: [[String: Any]] = try document.notes.map { note in
            ["guid": note.sourceAttributes["guid"] ?? "", "anchorKind": note.anchor.kind.rawValue,
             "titleSHA256": hash(Data(note.title.utf8)), "bodySHA256": hash(Data(note.sourceBody.utf8)),
             "attributesSHA256": hash(try encoder.encode(note.sourceAttributes)), "hasNativeCoordinates": note.anchor.location != nil]
        }
        let report: [String: Any] = ["schemaVersion": 1, "kind": document.kind.rawValue,
            "sourceSHA256": hash(data), "notes": notes, "verseCount": document.verses.count,
            "references": document.verses.map(\.reference), "referenceAttributes": document.referenceAttributes,
            "presentation": document.presentation, "roundTripEquivalent": roundTrip == document,
            "originalAnchorsTranslated": false, "generalParityVerified": false]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
