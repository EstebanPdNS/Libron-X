import Foundation
import CryptoKit
import Testing
@testable import MacRebuild

struct FilenPublicClientTests {
    @Test func publicMetadataV3AuthenticatesAndPreservesUnicode() throws {
        let key = Data(repeating: 0x38, count: 32)
        let plaintext = Data("{\"name\":\"Español — notas\",\"key\":\"example\"}".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        let metadata = "003" + FilenPublicClient.hex(sealed.nonce) + (sealed.ciphertext + sealed.tag).base64EncodedString()
        #expect(try FilenPublicClient.metadata(metadata, key: FilenPublicClient.hex(key)) == plaintext)
        #expect(throws: (any Error).self) {
            try FilenPublicClient.metadata(metadata, key: String(repeating: "00", count: 32))
        }
        #expect(throws: (any Error).self) { try FilenPublicClient.keyBytes("invalid") }
    }
    @Test func publicMetadataV2UsesItsSpecifiedPasswordDerivation() throws {
        let password = Data("12345678901234567890123456789012".utf8)
        let derived = Data(HMAC<SHA512>.authenticationCode(for: password + Data([0,0,0,1]), using: SymmetricKey(data: password)).prefix(32))
        let nonce = Data("abcdefghijkl".utf8), plaintext = Data("{\"name\":\"Connection Test\"}".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: derived), nonce: AES.GCM.Nonce(data: nonce))
        let metadata = "002abcdefghijkl" + (sealed.ciphertext + sealed.tag).base64EncodedString()
        #expect(try FilenPublicClient.metadata(metadata, key: String(decoding: password, as: UTF8.self)) == plaintext)
    }
    @Test func unsupportedPublicLinkFailsBeforeNetwork() async {
        let client = FilenPublicClient()
        await #expect(throws: (any Error).self) { try await client.folder(URL(string: "https://example.com/d/resource#secret")!) }
    }
}
