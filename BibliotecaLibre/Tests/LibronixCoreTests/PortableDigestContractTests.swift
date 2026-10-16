import Foundation
import Testing
@testable import LibronixCore

@Suite struct PortableDigestContractTests {
    @Test func publishedSHA256VectorsRemainStable() {
        #expect(LibrarySearchService.textFingerprint("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(LibrarySearchService.textFingerprint("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func fingerprintsUseExactUTF8WithoutNormalization() {
        #expect(LibrarySearchService.textFingerprint("Σαλώμ שלום 😀") == "ef23dd7ef5e767eb33d4fa6f02b4fe07a5ec939ae7fe55b222569bfded273391")
        #expect(LibrarySearchService.textFingerprint("\u{00e9}") == "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c")
        #expect(LibrarySearchService.textFingerprint("e\u{0301}") == "bf12767b0f2a56b2190075bae8169f656e3ce8d6357d4aff184bc6c7ea48f9f6")
    }
}
