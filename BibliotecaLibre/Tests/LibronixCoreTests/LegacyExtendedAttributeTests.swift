import Foundation
import Testing
@testable import LibronixCore

struct LegacyExtendedAttributeTests {
    private func data(_ hex: String) -> Data {
        var bytes = Data(); var start = hex.startIndex
        while start < hex.endIndex { let end = hex.index(start, offsetBy: 2); bytes.append(UInt8(hex[start..<end], radix: 16)!); start = end }
        return bytes
    }
    private func decode(_ bytes: Data) throws -> LegacySectionContent {
        try LegacyContentReader.decodeSimpleLatinRuns(bytes, section: .init(ordinal: 0, headerOffset: 94, payloadOffset: 100,
            storedLength: UInt32(bytes.count), decodedLength: UInt32(bytes.count), mode: 0, codecWord: nil))
    }
    @Test func zeroExtensionFlags() throws {
        let content = try decode(data("340000001100010000000100010000000100000001000100010000000000000002000000110000000df000000100090400510000"))
        #expect(content.plainText == "Q")
        let attributes = try #require(content.runs.first?.extendedAttributes)
        #expect(attributes.flags == 0)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == [])
        #expect(attributes.values == [])
        #expect(attributes.unparsedTail.isEmpty)
    }
    @Test func nonzeroFlagsEmptyBlob() throws {
        let content = try decode(data("360000001100010000000100010000000100000001000100010000000000000002000000110000000df0010000000100090400510000"))
        #expect(content.plainText == "Q")
        let attributes = try #require(content.runs.first?.extendedAttributes)
        #expect(attributes.flags == 1)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == [])
        #expect(attributes.values == [])
        #expect(attributes.unparsedTail.isEmpty)
    }
    @Test func oneString() throws {
        let content = try decode(data("410000001100010000000100010000000100000001000100010000000000000002000000110000000df001000b0001000700666978747572650100090400510000"))
        #expect(content.plainText == "Q")
        let attributes = try #require(content.runs.first?.extendedAttributes)
        #expect(attributes.flags == 1)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == ["fixture"])
        #expect(attributes.values == [])
        #expect(attributes.unparsedTail.isEmpty)
    }
    @Test func twoStrings() throws {
        let content = try decode(data("420000001100010000000100010000000100000001000100010000000000000002000000110000000df001000c00020003006f6e65030074776f0100090400510000"))
        #expect(content.plainText == "Q")
        let attributes = try #require(content.runs.first?.extendedAttributes)
        #expect(attributes.flags == 1)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
        #expect(attributes.values == [])
        #expect(attributes.unparsedTail.isEmpty)
    }
    @Test func oneNumericValue() throws {
        let content = try decode(data("3c0000001100010000000100010000000100000001000100010000000000000002000000110000000df0020006000100443322110100090400510000"))
        #expect(content.plainText == "Q")
        let attributes = try #require(content.runs.first?.extendedAttributes)
        #expect(attributes.flags == 2)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == [])
        #expect(attributes.values == [287454020])
        #expect(attributes.unparsedTail.isEmpty)
    }
    @Test func stringThenTwoValues() throws {
        let content = try decode(data("4b0000001100010000000100010000000100000001000100010000000000000002000000110000000df00300150001000700666978747572650200070000000b0000000100090400510000"))
        #expect(content.plainText == "Q")
        let attributes = try #require(content.runs.first?.extendedAttributes)
        #expect(attributes.flags == 3)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == ["fixture"])
        #expect(attributes.values == [7, 11])
        #expect(attributes.unparsedTail.isEmpty)
    }
    @Test func zeroCounts() throws {
        let content = try decode(data("3a0000001100010000000100010000000100000001000100010000000000000002000000110000000df003000400000000000100090400510000"))
        #expect(content.plainText == "Q")
        let attributes = try #require(content.runs.first?.extendedAttributes)
        #expect(attributes.flags == 3)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == [])
        #expect(attributes.values == [])
        #expect(attributes.unparsedTail.isEmpty)
    }
    @Test func namedGraphZeroExtensionFlags() throws {
        let content = try decode(data("3a0000001100010000000100010000000100000001000100010000000000000002000000610000000df000000c0021666978747572652e626d70"))
        #expect(content.plainText == "￼")
        let attributes = try #require(content.graphics.first?.extendedAttributes)
        #expect(attributes.flags == 0)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == [])
        #expect(attributes.values == [])
        #expect(attributes.unparsedTail.isEmpty)
    }
    @Test func char13ZeroExtensionFlags() throws {
        let content = try decode(data("380000001100010000000100010000000100000001000100010000000000000002000000130000000df00000000000000100090400510000"))
        #expect(content.plainText == "Q")
        let attributes = try #require(content.runs.first?.extendedAttributes)
        #expect(attributes.flags == 0)
        #expect(attributes.strings.map { String(decoding: $0, as: UTF8.self) } == [])
        #expect(attributes.values == [])
        #expect(attributes.unparsedTail.isEmpty)
        #expect(content.runs.first?.extraValue == 0)
    }
    @Test func negativeInnerCountsAndTruncatedOuterBlobsAreRejected() throws {
        var bytes = data("410000001100010000000100010000000100000001000100010000000000000002000000110000000df001000b0001000700666978747572650100090400510000")
        bytes[46] = 255; bytes[47] = 255
        #expect(throws: LegacyContentError.self) { try decode(bytes) }
        for count in [39, 41, 43, 45, 47, 50] {
            var truncated = Data(bytes.prefix(count))
            for index in 0..<4 { truncated[index] = UInt8(truncatingIfNeeded: count >> (8 * index)) }
            #expect(throws: LegacyContentError.self) { try decode(truncated) }
        }
    }
    @Test func unknownFlagsAndUnusedBlobBytesAreRetainedWithoutShiftingTheBody() throws {
        var bytes = data("360000001100010000000100010000000100000001000100010000000000000002000000110000000df0010000000100090400510000")
        bytes[42] = 0; bytes[43] = 128; bytes[44] = 2
        bytes.insert(contentsOf: [187, 204], at: 46); bytes[0] += 2
        let result = try decode(bytes), attributes = try #require(result.runs.first?.extendedAttributes)
        #expect(result.plainText == "Q" && attributes.flags == 32768)
        #expect(attributes.unparsedTail == Data([187,204]) && attributes.rawData == Data([187,204]))
    }
}
