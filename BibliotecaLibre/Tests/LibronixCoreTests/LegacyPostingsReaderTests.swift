import Foundation
import Testing
@testable import LibronixCore

struct LegacyPostingsReaderTests {
    private let one = hex("000000000700000001000a000000050600")
    // Independently encoded binary-literal DCL stream for `one`, including its
    // terminator. No original index packet is embedded in the source package.
    private let compressedOne = hex("000400000000e0000000000200500000008002060002fe01")

    @Test func leadingMetadataDoesNotControlHitTraversal() throws {
        let parsed = try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: 1)
        #expect(parsed.leadingMetadataWord == 0)
        #expect(parsed.hitCount == 1 && !parsed.leadingWordMatchesGroupCount)
        #expect(parsed.groups[0].articleBits == 7)
        #expect(parsed.groups[0].decodedOffset == 4)
        #expect(parsed.groups[0].postings[0].decodedOffset == 10)
        #expect(parsed.groups[0].postings[0].positionBits == 10)
        #expect(parsed.groups[0].postings[0].extentBits == 5)
        #expect(parsed.groups[0].postings[0].metadataBits == 6)
    }

    @Test func preservesAllUnsignedWireBits() throws {
        let bytes = hex("07000000ffffffff0100ffffffffff ffff")
        let parsed = try LegacyPostingsReader.decodeNumericPayload(bytes, expectedHitCount: 1)
        #expect(parsed.leadingMetadataWord == 7)
        #expect(parsed.groups[0].articleBits == UInt32.max)
        #expect(parsed.groups[0].postings[0].positionBits == UInt32.max)
        #expect(parsed.groups[0].postings[0].extentBits == UInt8.max)
        #expect(parsed.groups[0].postings[0].metadataBits == UInt16.max)
    }

    @Test func preservesUnsortedGroupAndHitOrder() throws {
        let bytes = hex("020000000900000002000f0000000306000300000004070002000000010008000000050800")
        let parsed = try LegacyPostingsReader.decodeNumericPayload(bytes, expectedHitCount: 3)
        #expect(parsed.groups.map(\.articleBits) == [9, 2])
        #expect(parsed.groups[0].postings.map(\.positionBits) == [15, 3])
        #expect(parsed.groups[0].postings.map(\.extentBits) == [3, 4])
        #expect(parsed.groups[0].postings.map(\.metadataBits) == [6, 7])
        #expect(parsed.groups[1].postings[0].positionBits == 8)
        #expect(parsed.hitCount == 3 && parsed.leadingWordMatchesGroupCount)
    }

    @Test func emptyHitListRetainsItsIndependentMetadata() throws {
        let parsed = try LegacyPostingsReader.decodeNumericPayload(hex("34120000"), expectedHitCount: 0)
        #expect(parsed.leadingMetadataWord == 0x1234)
        #expect(parsed.groups.isEmpty && parsed.hitCount == 0)
        #expect(!parsed.leadingWordMatchesGroupCount)
        #expect(throws: LegacyPostingsError.trailingData) {
            try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: 0)
        }
    }

    @Test func rawBlocksMaySplitEveryNumericFieldBoundary() throws {
        let expected = try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: 1)
        for split in 1..<one.count {
            let packet = header() + block(Data(one.prefix(split)), last: false) + block(Data(one.dropFirst(split)))
            #expect(try LegacyPostingsReader.decodePacket(packet, expectedHitCount: 1) == expected)
        }
    }

    @Test func nonzeroCompressionFlagAndSmallHintAllowBoundedGrowth() throws {
        let packet = header(hint: 1) + block(compressedOne, indicator: 2)
        let parsed = try LegacyPostingsReader.decodePacket(packet, expectedHitCount: 1)
        #expect(parsed == (try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: 1)))
        #expect(parsed.decodedByteCount == 17)
        #expect(throws: LegacyPostingsError.limitExceeded) {
            try LegacyPostingsReader.decodePacket(packet, expectedHitCount: 1,
                limits: .init(maximumDecodedBytes: 16))
        }
    }

    @Test func rawAndCompressedBlocksComposeOneStream() throws {
        // A separately encoded four-byte metadata block followed by a raw
        // group/hit body proves mixed framing and numeric-field composition.
        let compressedPrefix = hex("00040000000010f00f")
        let rawSuffix = Data(one.dropFirst(4))
        let packet = header(hint: 1) + block(compressedPrefix, indicator: 1, last: false) + block(rawSuffix)
        #expect(try LegacyPostingsReader.decodePacket(packet, expectedHitCount: 1).groups[0].articleBits == 7)
        let compressed = header(hint: 1) + block(compressedOne, indicator: 1, last: false) + block(hex("00"))
        #expect(throws: LegacyPostingsError.trailingData) {
            try LegacyPostingsReader.decodePacket(compressed, expectedHitCount: 1)
        }
    }

    @Test func rejectsNonpositiveSignedGroupCountsAsExplicitGuards() throws {
        for (wire, count) in [(UInt16(0), Int16(0)), (UInt16.max, Int16(-1)), (UInt16(0x8000), Int16.min)] {
            var bytes = one
            bytes.replaceSubrange(8..<10, with: le16(wire))
            #expect(throws: LegacyPostingsError.invalidGroupCount(count)) {
                try LegacyPostingsReader.decodeNumericPayload(bytes, expectedHitCount: 1)
            }
        }
    }

    @Test func everyTruncatedNumericPrefixFailsWithoutPartialResults() {
        for length in 0..<one.count {
            #expect(throws: (any Error).self) {
                try LegacyPostingsReader.decodeNumericPayload(Data(one.prefix(length)), expectedHitCount: 1)
            }
        }
        #expect(throws: LegacyPostingsError.invalidNumericPayload) {
            try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: 2)
        }
        #expect(throws: LegacyPostingsError.trailingData) {
            try LegacyPostingsReader.decodeNumericPayload(one + Data([0]), expectedHitCount: 1)
        }
    }

    @Test func budgetsFailBeforeUntrustedCountsCanAllocate() {
        #expect(throws: LegacyPostingsError.limitExceeded) {
            try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: UInt32.max)
        }
        #expect(throws: LegacyPostingsError.limitExceeded) {
            try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: 1,
                limits: .init(maximumHits: 0))
        }
        #expect(throws: LegacyPostingsError.limitExceeded) {
            try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: 1,
                limits: .init(maximumGroups: 0))
        }
        #expect(throws: LegacyPostingsError.invalidLimits) {
            try LegacyPostingsReader.decodePacket(Data(), expectedHitCount: 0,
                limits: .init(maximumDecodedBytes: Int.max))
        }
        let packet = header() + block(Data(one.prefix(4)), last: false) + block(Data(one.dropFirst(4)))
        #expect(throws: LegacyPostingsError.limitExceeded) {
            try LegacyPostingsReader.decodePacket(packet, expectedHitCount: 1,
                limits: .init(maximumBlocks: 1))
        }
    }

    @Test func packetHeadersLengthsLastFlagAndTailAreChecked() {
        let packet = header() + block(one)
        for length in 0..<packet.count {
            #expect(throws: (any Error).self) {
                try LegacyPostingsReader.decodePacket(Data(packet.prefix(length)), expectedHitCount: 1)
            }
        }
        #expect(throws: LegacyPostingsError.unsupportedStream(external: 2, mode: 1)) {
            try LegacyPostingsReader.decodePacket(le16(2) + Data(packet.dropFirst(2)), expectedHitCount: 1)
        }
        #expect(throws: LegacyPostingsError.invalidPacket) {
            try LegacyPostingsReader.decodePacket(header(hint: 0) + block(one), expectedHitCount: 1)
        }
        #expect(throws: LegacyPostingsError.invalidPacket) {
            try LegacyPostingsReader.decodePacket(header() + block(one, last: false), expectedHitCount: 1)
        }
        #expect(throws: LegacyPostingsError.trailingData) {
            try LegacyPostingsReader.decodePacket(packet + Data([0]), expectedHitCount: 1)
        }
        #expect(throws: LegacyPostingsError.invalidPacket) {
            try LegacyPostingsReader.decodePacket(header() + Data([0]) + le16(0x8000), expectedHitCount: 1)
        }
    }

    @Test func compressedWholeByteTailsAreRejectedBySeparateStrictAPI() {
        #expect(throws: LegacyPostingsError.decompressionFailed(-102)) {
            try LegacyPostingsReader.decodePacket(header() + block(compressedOne + Data([0]), indicator: 1), expectedHitCount: 1)
        }
        #expect(throws: LegacyPostingsError.decompressionFailed(-1)) {
            try LegacyPostingsReader.decodePacket(header() + block(hex("0204ffff"), indicator: 1), expectedHitCount: 1)
        }
        #expect(throws: LegacyPostingsError.decompressionFailed(-2)) {
            try LegacyPostingsReader.decodePacket(header() + block(hex("0003ffff"), indicator: 1), expectedHitCount: 1)
        }
    }

    @Test func readsBothDictionaryRowBoundariesWithoutNormalizingKeys() throws {
        try withPair { lsf, lix in
            let originalLSF = try Data(contentsOf: lsf), originalLIX = try Data(contentsOf: lix)
            let first = try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix, dictionaryRow: 0)
            let last = try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix, dictionaryRow: 1)
            #expect(first.dictionaryKeyBytes == hex("004f776e00"))
            #expect(last.dictionaryKeyBytes == hex("025a00"))
            #expect(first.postings.expectedHitCount == 1 && last.postings.expectedHitCount == 1)
            #expect(first.postings.leadingMetadataWord == 0 && last.postings.leadingMetadataWord == 7)
            #expect(first.postings.groups[0].articleBits == 7)
            #expect(last.postings.groups[0].articleBits == UInt32.max)
            #expect(last.packetFileOffset == first.packetFileOffset + UInt64(first.packetByteCount))
            #expect(try Data(contentsOf: lsf) == originalLSF)
            #expect(try Data(contentsOf: lix) == originalLIX)
            for row in [-1, 2] {
                #expect(throws: LegacyPostingsError.dictionaryRowNotFound(row)) {
                    try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix, dictionaryRow: row)
                }
            }
        }
    }

    @Test func rejectsWrongPairAndContradictoryDictionaryOffsets() throws {
        try withPair(mismatch: true) { lsf, lix in
            #expect(throws: LegacyPostingsError.mismatchedPair) {
                try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix, dictionaryRow: 0)
            }
        }
        try withPair(badOffset: true) { lsf, lix in
            #expect(throws: LegacyPostingsError.invalidIndex("BWDX/row offsets")) {
                try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix, dictionaryRow: 0)
            }
        }
        try withPair(wrongHitCount: true) { lsf, lix in
            #expect(throws: LegacyPostingsError.invalidNumericPayload) {
                try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix, dictionaryRow: 0)
            }
        }
    }

    private func header(hint: UInt16 = 8192) -> Data { le16(0) + le16(1) + le16(hint) }
    private func block(_ data: Data, indicator: UInt8 = 0, last: Bool = true) -> Data {
        Data([indicator]) + le16(UInt16(data.count) | (last ? 0x8000 : 0)) + data
    }

    private struct Chunk {
        let tag: String
        let bytes: Data
        let children: [Chunk]
        init(_ tag: String, _ bytes: Data = Data(), children: [Chunk] = []) {
            self.tag = tag; self.bytes = bytes; self.children = children
        }
        var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
        var size: Int { children.isEmpty ? bytes.count : children.reduce(0) { $0 + 8 + $1.size } }
    }

    private func withPair(mismatch: Bool = false, badOffset: Bool = false, wrongHitCount: Bool = false,
                          _ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lsf = directory.appendingPathComponent("Own.LSF"), lix = directory.appendingPathComponent("Own.LIX")
        let identifier = hex("01000000030000003500")
        try container("GTTL", [Chunk("bkid", identifier)]).write(to: lsf)
        let first = header(hint: 1) + block(compressedOne, indicator: 2)
        let last = header() + block(hex("07000000ffffffff0100ffffffffff ffff"))
        let records = le32(0) + le32(0) + le32(wrongHitCount ? 2 : 1) +
            le32(5) + le32(badOffset ? UInt32.max : UInt32(first.count)) + le32(1)
        let bodyIndex = Chunk("BWDX", children: [Chunk("info", le16(0) + le32(2) + le16(1)),
            Chunk("klst", hex("004f776e00025a00")), Chunk("hlst", records), Chunk("hits", first + last)])
        let indexID = le16(1) + (mismatch ? Data(repeating: 0, count: 10) : identifier)
        try container("BIDX", [Chunk("bkid", indexID), bodyIndex]).write(to: lix)
        try body(lsf, lix)
    }

    private func container(_ kind: String, _ chunks: [Chunk]) -> Data {
        let directorySize = 18 + chunks.reduce(0) { $0 + $1.count } * 18
        var prefix = Data(repeating: 0, count: 44)
        prefix.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        prefix.replaceSubrange(8..<12, with: Data(kind.utf8))
        prefix.replaceSubrange(36..<40, with: Data("pcr ".utf8))
        prefix.replaceSubrange(40..<44, with: le32(UInt32(directorySize)))
        var directory = Data("LSFF\(kind)".utf8) + Data(repeating: 0, count: 10)
        var payload = Data()
        func emit(_ chunk: Chunk, at offset: Int) -> Data {
            directory.append(Data(chunk.tag.utf8) + le32(0) + le32(UInt32(chunk.size)) +
                le32(UInt32(offset + 8)) + le16(UInt16(chunk.children.count)))
            var output = Data(chunk.tag.utf8) + le32(UInt32(chunk.size))
            if chunk.children.isEmpty { output.append(chunk.bytes) }
            else { for child in chunk.children { output.append(emit(child, at: offset + output.count)) } }
            return output
        }
        for chunk in chunks { payload.append(emit(chunk, at: 44 + directorySize + payload.count)) }
        var result = prefix + directory + payload
        result.replaceSubrange(4..<8, with: le32(UInt32(result.count - 8)))
        return result
    }

    private func le16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
    private func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
}

private func hex(_ value: String) -> Data {
    let compact = value.filter { !$0.isWhitespace }
    return Data(stride(from: 0, to: compact.count, by: 2).map {
        let start = compact.index(compact.startIndex, offsetBy: $0)
        let end = compact.index(start, offsetBy: 2)
        return UInt8(compact[start..<end], radix: 16)!
    })
}
