import Foundation
import Testing
@testable import LibronixCore

struct LegacyReferenceRun2Tests {
    private func fixture(reference: Data, flags: UInt16 = 0, format: UInt16 = 0, length: UInt32? = nil) -> Data {
        var body = Data()
        func word(_ x: UInt16) { body.append(UInt8(truncatingIfNeeded: x)); body.append(UInt8(truncatingIfNeeded: x >> 8)) }
        func integer(_ x: UInt32) { word(UInt16(truncatingIfNeeded: x)); word(UInt16(truncatingIfNeeded: x >> 16)) }
        integer(0); word(17); integer(1)
        word(1); word(1); word(0); integer(1)
        word(1); word(1); word(2); word(0); word(0); word(0); word(2); word(0)
        word(0x52); word(flags); word(format); integer(length ?? UInt32(reference.count - 1)); body.append(reference)
        word(0x12); word(1); body.append(contentsOf: [0, 81, 0])
        for i in 0..<4 { body[i] = UInt8(truncatingIfNeeded: body.count >> (8 * i)) }
        return body
    }
    private func decode(_ data: Data) throws -> LegacySectionContent {
        try LegacyContentReader.decodeSimpleLatinRuns(data, section: .init(ordinal: 0, headerOffset: 0, payloadOffset: 6,
            storedLength: UInt32(data.count), decodedLength: UInt32(data.count), mode: 0, codecWord: nil))
    }
    @Test func terminatedReferencePreservesFlagsAndDoesNotShiftTextOrStyles() throws {
        let raw = Data("bible.1.1.1\0".utf8)
        for format: UInt16 in [0, 1, 0x8001] {
            let content = try decode(fixture(reference: raw, flags: 0x10, format: format))
            let anchor = try #require(content.anchors.first)
            #expect(content.plainText == "Q" && content.runs.first?.characterOffset == 0)
            #expect(content.runs.first?.styleIdentifier == 0)
            #expect(anchor.sourceToken == 0x52 && anchor.flags == 0x10)
            #expect(anchor.referenceFormatFlags == format && anchor.serializedReference == raw)
            #expect(anchor.reference == "bible.1.1.1" && anchor.characterOffset == 0)
            #expect(anchor.dataTypeCode == (format & 1 == 0 ? 0x10 : 0x20))
        }
    }
    @Test func legacyVNPReferenceConsumesThreeSignedWordsWithoutChangingFollowingText() throws {
        var data = fixture(reference: Data("bible.1.1.1\0".utf8))
        data.replaceSubrange(36..<58, with: [0x51,0, 0x80,0, 4,0, 0,0, 0xff,0xff, 0xb6,1])
        for i in 0..<4 { data[i] = UInt8(truncatingIfNeeded: data.count >> (8 * i)) }
        let result = try decode(data), anchor = try #require(result.anchors.first)
        #expect(result.plainText == "Q" && result.runs.first?.characterOffset == 0)
        #expect(anchor.dataTypeCode == 4 && anchor.flags == 0x80 && anchor.reference == nil)
        #expect(anchor.structuredReference?.schemeBytes == Data("VNP".utf8))
        #expect(anchor.structuredReference?.componentBits == [0, UInt32.max, 438])
    }
    @Test func articlePrefixesRetainSourceRangesAndDoNotShiftTextCoordinates() throws {
        let plain = fixture(reference: Data("bible.1.1.1\0".utf8))
        func prefixed(flags: UInt32, prefix: Data) -> Data {
            var result = plain
            result.insert(contentsOf: prefix, at: 10)
            for i in 0..<4 {
                result[i] = UInt8(truncatingIfNeeded: result.count >> (8 * i))
                result[6 + i] = UInt8(truncatingIfNeeded: flags >> (8 * i))
            }
            return result
        }
        // rangeIdentifier=7, count=1, name="key", positions=9/20;
        // referencePrefix length=3, bytes="ref". Prefix order is 0x40, 0x10.
        let ranges = Data([7,0,0,0, 1,0, 3,0, 107,101,121, 9,0,0,0, 20,0,0,0])
        let reference = Data([3,0, 114,101,102])
        for (flags, prefix) in [(UInt32(0x21), Data()), (0x11, reference), (0x41, ranges), (0x71, ranges + reference)] {
            let result = try decode(prefixed(flags: flags, prefix: prefix))
            #expect(result.plainText == "Q" && result.runs[0].characterOffset == 0)
            #expect(result.documentSourceFlags == flags && result.paragraphDocuments?[0].decodedStart == UInt64(10 + prefix.count))
            let header = try #require(result.storedHeader)
            if flags & 0x40 != 0 {
                #expect(header.rangeIdentifier == 7)
                #expect(header.rangeEntries.first?.name == Data("key".utf8))
                #expect(header.rangeEntries.first?.firstPosition == 9 && header.rangeEntries.first?.secondPosition == 20)
            }
            if flags & 0x10 != 0 { #expect(header.referencePrefix == Data("ref".utf8)) }
        }
        for prefix in [Data([7,0,0,0,255,255]), Data([7,0,0,0,1,0,255,255]), Data([7,0,0,0,1,0,100,0])] {
            #expect(throws: LegacyContentError.self) { try decode(prefixed(flags: 0x41, prefix: prefix)) }
        }
    }
    @Test func malformedLengthsAndTerminatorsCannotConsumeTheFollowingRun() throws {
        for raw in [Data("bible.1.1.1X".utf8), Data("bible.1\0.1\0".utf8)] {
            #expect(throws: LegacyContentError.self) { try decode(fixture(reference: raw)) }
        }
        #expect(throws: LegacyContentError.self) { try decode(fixture(reference: Data([0]), length: UInt32.max)) }
        #expect(throws: LegacyContentError.self) { try decode(fixture(reference: Data([0]), length: 400)) }
    }
}
