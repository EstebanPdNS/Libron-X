import Foundation
import CryptoKit
import Testing
@testable import MacRebuild

@Suite struct ResourceDownloadCodeTests {
    private let key = "0123456789ABCDEFGHIJKLMNOPQRST"

    @Test func encryptedCodeRoundTripAndResourceDecryption() throws {
        let url = URL(string: "https://example.com/Spanish%20Bibles.lxcollection")!
        let text = try ResourceDownloadCode.encode(url: url, embeddedKey: key)
        #expect(text.hasPrefix("LX2."))
        #expect(!text.contains(key))
        #expect(!text.contains("example.com"))
        let decoded = try ResourceDownloadCode.decode(text, embeddedKey: key)
        #expect(decoded.url == url)
        let plain = Data("Native resource payload".utf8)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: SHA256.hash(data: Data(key.utf8))))
        #expect(try decoded.open(#require(box.combined)) == plain)
    }

    @Test func encryptedCodeRequiresMatchingEmbeddedKey() throws {
        let text = try ResourceDownloadCode.encode(url: URL(string: "https://example.com/catalog")!, embeddedKey: key)
        #expect(throws: (any Error).self) { try ResourceDownloadCode.decode(text, embeddedKey: nil) }
        #expect(throws: (any Error).self) { try ResourceDownloadCode.decode(text, embeddedKey: String(repeating: "x", count: 30)) }
        #expect(throws: (any Error).self) { try ResourceDownloadCode.encode(url: URL(string: "http://example.com/catalog")!, embeddedKey: key) }
    }

    @Test func invalidKeysAndLegacyCompatibility() throws {
        #expect(ResourceDownloadKey.validated(Data(repeating: 65, count: 29)) == nil)
        #expect(ResourceDownloadKey.validated(Data((key.dropLast() + "!").utf8)) == nil)
        let legacy = ResourceDownloadCode(version: 1, url: URL(string: "https://example.com/catalog")!, key: key)
        let text = "LX1." + (try JSONEncoder().encode(legacy)).base64EncodedString()
        #expect(try ResourceDownloadCode.decode(text, embeddedKey: nil).url == legacy.url)
    }
}
