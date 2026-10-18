import Foundation
import Testing
@testable import LibronixCore

struct NativePackageCopyTests {
    @Test func importingPortablePackageKeepsItsIndependentNativeReaderAndReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("authored.epub")
        try Data("Authored retained source container".utf8).write(to: source)
        var metadata = LibronMetadata(title: "Authored native study book", origin: "EPUB")
        metadata.resourceType = "Biblia"
        let input = LibraryResource(location: source, title: metadata.title, byteCount: Int64(try Data(contentsOf: source).count),
            format: .epub, support: .metadataOnly, provenance: .libronixMetadata, libron: metadata)
        let package = try LibronPackage.create(input, in: root.appendingPathComponent("First"), backup: false)
        let folder = package.appendingPathComponent("normalized")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appendingPathComponent("reader.sqlite")
        do {
            let db = try LibronNativeDatabase(database, create: true)
            try db.put("authored-native-commentary", data: Data("Retained notes, images and tables".utf8))
            try db.add(reference: "Ge 1:1", ordinal: 0, offset: 0)
            try db.finish()
        }
        try LibronPackage.registerNormalizedContent(in: package)
        let receipt: [String: Any] = ["sourceSHA256": try LibronPackage.hash(source), "resourceID": input.id, "state": "complete"]
        let receiptData = try JSONSerialization.data(withJSONObject: receipt)
        try receiptData.write(to: folder.appendingPathComponent("conversion.json"))
        let destination = root.appendingPathComponent("Second")
        let imported = try await LibronLibrary().convert([package], to: destination, backup: false)
        let copied = try #require(imported.first?.packageLocation)
        let manifest = try LibronPackage.read(copied, verify: true).0
        #expect(imported.count == 1 && manifest.id == input.id)
        let originalNativeHash = try LibronPackage.hash(database)
        #expect(manifest.normalizedContent?.sha256 == originalNativeHash)
        let db = try LibronNativeDatabase(copied.appendingPathComponent("normalized/reader.sqlite"))
        #expect(try db.get("authored-native-commentary") == Data("Retained notes, images and tables".utf8))
        #expect(try db.resolve("Ge 1:1")?.ordinal == 0)
        #expect(try Data(contentsOf: copied.appendingPathComponent("normalized/conversion.json")) == receiptData)
        #expect(try LibronPackage.hash(try #require(imported.first).location) == LibronPackage.hash(source))
    }
}
