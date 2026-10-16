import Foundation
import Testing
@testable import LibronixCore

struct LTESContainerReaderTests {
    // Own synthetic archive; context [1,2,3,4] has no relationship to original packages.
    private let fixtureHex = [
        "4c544553000001014101000000000000ef43c3e57bbae0cfd9dcd7144e60d6678200e82799bb3fa8b35219d721ad79ba",
        "c63f795550f11c770eb1f40d7a8ffe3a94bbbd2ac6a764ec51b4fa2759ad3be55affc5f7650a31d104525a8b5976c724",
        "85321ad5f156b73a46a25ea761145adc0cd5fb8ad3715d7d92e1d36357fbc7c1e831f5979b8a396fc3e5ccda79039d49",
        "6c96170c3ba82d734d52e9de39f5bd526858447c323c390fb4eaecfecd4465b944ee459209ffadf4ade66672b069dc13",
        "100ec53130001463276a786dd91110d881bd0eb1d751edac3d5b4fb1bbc0c11a56293cca5576b3f6e62e51c90b38f1bf",
        "433509850c0e5c151ad2afff744bcccb3f04640c88d614108d1ae4f0c3d21df7627477347a3b1caf433e8a882a14647b",
        "75390a5e2dc21dd1ed2ae76e798c892a7aeff0e57fbd1958023080fab63b90f5c6f564a9027efa3d49c6e9bd90092283",
        "1ff8bb5ddf19a482efd064c6a88861a8"
    ].joined()
    private var fixture: Data {
        let pairs = stride(from: 0, to: fixtureHex.count, by: 2)
        return Data(pairs.map { offset in
            let start = fixtureHex.index(fixtureHex.startIndex, offsetBy: offset)
            return UInt8(fixtureHex[start..<fixtureHex.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    @Test func decodesIndexedZlibNestedDirectoriesAndEmptyFiles() throws {
        let archive = try LTESContainerReader.decodeConfiguration(fixture, context: LTESKeyMaterial(words: [1,2,3,4]))
        #expect(archive.metadata.name == "lbx-company")
        #expect(archive.metadata.attributes["name"] == "Synthetic")
        #expect(archive.directoryCount == 1)
        #expect(archive.compressedBlockCount == 6)
        #expect(archive.decodedByteCount == 227)
        #expect(archive.entries.map(\.path) == ["index.xml", "Folder/empty.xml"])
        #expect(try archive.readEntry(path: "index.xml") == Data("metadata fixture".utf8))
        #expect(try archive.readEntry(path: "Folder/empty.xml").isEmpty)
        #expect(throws: LTESReadError.limitExceeded) { try archive.readEntry(path: "index.xml", maximumBytes: 15) }
        #expect(throws: LTESReadError.entryNotFound) { try archive.readEntry(path: "../index.xml") }
    }

    @Test func contextMismatchDoesNotProduceArchive() throws {
        #expect(throws: LTESReadError.contextMismatch) {
            try LTESContainerReader.decodeConfiguration(fixture, context: LTESKeyMaterial(words: [0,0,0,0]))
        }
        #expect(throws: LTESReadError.invalidContextShape) { try LTESKeyMaterial(words: [1,2,3]) }
        #expect(String(describing: try LTESKeyMaterial(words: [1,2,3,4])) == "LTESKeyMaterial(redacted)")
    }

    @Test func rejectsTruncationAndUnvalidatedVersion() throws {
        #expect(throws: LTESReadError.invalidLTES) {
            try LTESContainerReader.decodeConfiguration(fixture.dropLast(), context: LTESKeyMaterial(words: [1,2,3,4]))
        }
        var old = fixture; old[6] = 0
        #expect(throws: LTESReadError.unsupportedVersion) {
            try LTESContainerReader.decodeConfiguration(old, context: LTESKeyMaterial(words: [1,2,3,4]))
        }
        var enormous = fixture; for index in 8..<16 { enormous[index] = 255 }
        #expect(throws: LTESReadError.limitExceeded) {
            try LTESContainerReader.decodeConfiguration(enormous, context: LTESKeyMaterial(words: [1,2,3,4]))
        }
    }

    @Test func ignoresBookAndLicenseExtensionsBeforeConsultingProvider() throws {
        struct Provider: LTESConfigurationKeyProvider {
            func context(forConfigurationAt url: URL) throws -> LTESKeyMaterial {
                throw LTESReadError.contextMismatch
            }
        }
        for ext in ["lbxlls", "lbxoeb", "lbxlbk"] {
            #expect(throws: LTESReadError.unsupportedConfiguration) {
                try LTESContainerReader.inspectConfiguration(at: URL(fileURLWithPath: "/nonexistent/test." + ext), provider: Provider())
            }
        }
    }
}
