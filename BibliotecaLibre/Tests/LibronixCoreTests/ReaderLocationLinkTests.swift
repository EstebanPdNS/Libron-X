import Foundation
import Testing
@testable import LibronixCore

struct ReaderLocationLinkTests {
    @Test func roundTripsExactEditionAndPosition() throws {
        let location = ReaderLocation(resourceID: "/own library/Édition.LSF", legacyIdentifier: "edition-A", format: .legacyLSF,
            sectionOrdinal: 42, reference: "John 3:16", textFingerprint: String(repeating: "a", count: 64), characterOffset: 17)
        let url = try ReaderLocationLink.make(location)
        #expect(url.scheme == "libronx" && url.host == "location")
        #expect(try ReaderLocationLink.parse(url) == location)
    }
    @Test func rejectsMalformedAndUnboundedLinks() throws {
        for value in ["https://location/v1/e30", "libronx://other/v1/e30", "libronx://location/v1/e30?x=1", "libronx://location/v1/e30#fragment", "libronx://location/v2/e30", "libronx://location/v1/!!!"] {
            let url = try #require(URL(string: value))
            #expect(throws: (any Error).self) { try ReaderLocationLink.parse(url) }
        }
        let missingFingerprint = ReaderLocation(resourceID: "resource", format: .legacyLSF, sectionOrdinal: 0, characterOffset: 0)
        #expect(throws: (any Error).self) { try ReaderLocationLink.make(missingFingerprint) }
        let tooLong = ReaderLocation(resourceID: String(repeating: "a", count: 4097), format: .legacyLSF,
            sectionOrdinal: 0, textFingerprint: String(repeating: "a", count: 64), characterOffset: 0)
        #expect(throws: (any Error).self) { try ReaderLocationLink.make(tooLong) }
    }
}
