import Foundation
import Testing
@testable import LibronixCore

struct LegacyCompactPostingsReaderTests {
    private var one: Data { numeric(metadata: 99, groups: [(7, [(10, 5)])]) }

    @Test func leadingWordNeverControlsExternalTraversal() throws {
        let result = try LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 1)
        #expect(result.leadingMetadataWord == 99 && result.expectedHitCount == 1 && result.hitCount == 1)
        #expect(result.decodedByteCount == 15 && result.groups[0].decodedOffset == 4)
        #expect(result.groups[0].postings[0].decodedOffset == 10)
        #expect(result.groups[0].articleBits == 7 && result.groups[0].postings[0].extentBits == 5)
    }
    @Test func unsignedBitsZeroExtentsAndSourceOrderRemainRaw() throws {
        let raw = numeric(metadata: .max, groups: [(.max, [(.max, .max), (0, 0)]), (1, [(8, 2)])])
        let result = try LegacyCompactPostingsReader.decodeNumericPayload(raw, expectedHitCount: 3)
        #expect(result.leadingMetadataWord == .max && result.groups.map(\.articleBits) == [.max, 1])
        #expect(result.groups[0].postings.map(\.positionBits) == [.max, 0])
        #expect(result.groups[0].postings.map(\.extentBits) == [.max, 0])
        #expect(result.groups[1].decodedOffset == 20 && result.groups[1].postings[0].decodedOffset == 26)
    }
    @Test func zeroHitsKeepIndependentMetadataAndExactTail() throws {
        let value = try LegacyCompactPostingsReader.decodeNumericPayload(le32(.max), expectedHitCount: 0)
        #expect(value.leadingMetadataWord == .max && value.groups.isEmpty && value.hitCount == 0)
        #expect(throws: LegacyCompactPostingsError.trailingData) { try LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 0) }
    }
    @Test func everyTruncatedScalarPrefixFails() {
        for count in 0..<one.count {
            #expect(throws: (any Error).self) { try LegacyCompactPostingsReader.decodeNumericPayload(Data(one.prefix(count)), expectedHitCount: 1) }
        }
        #expect(throws: LegacyCompactPostingsError.invalidNumericPayload) { try LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 2) }
        #expect(throws: LegacyCompactPostingsError.trailingData) { try LegacyCompactPostingsReader.decodeNumericPayload(one + Data([0]), expectedHitCount: 1) }
    }
    @Test func signedGroupFailuresAreExplicitReconstructionPolicies() {
        for count in [Int16(0), -1, .min] {
            var raw = one; raw.replaceSubrange(8..<10, with: le16(UInt16(bitPattern: count)))
            #expect(throws: LegacyCompactPostingsError.invalidGroupCount(count)) { try LegacyCompactPostingsReader.decodeNumericPayload(raw, expectedHitCount: 1) }
        }
    }
    @Test func budgetsRejectUntrustedCountsBeforeAllocation() {
        #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: .max) }
        #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 1, limits: .init(maximumGroups: 0)) }
        #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 1, limits: .init(maximumDecodedBytes: 14)) }
        #expect(throws: LegacyCompactPostingsError.invalidLimits) { try LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 1, limits: .init(maximumHits: Int.max)) }
    }
    @Test func slicedDataKeepsStableNumericAndPacketOffsets() throws {
        let wrapped = Data([0xee]) + one
        #expect(wrapped.dropFirst().startIndex == 1)
        #expect(try LegacyCompactPostingsReader.decodeNumericPayload(wrapped.dropFirst(), expectedHitCount: 1) == LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 1))
        let framed = header() + block(one)
        #expect(try LegacyCompactPostingsReader.decodePacket((Data([0xee]) + framed).dropFirst(), expectedHitCount: 1).hitCount == 1)
    }
    @Test func rawBlocksCrossEveryScalarBoundary() throws {
        let expected = try LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 1)
        for split in 1..<one.count {
            let packet = header() + block(Data(one.prefix(split)), last: false) + block(Data(one.dropFirst(split)))
            #expect(try LegacyCompactPostingsReader.decodePacket(packet, expectedHitCount: 1) == expected)
        }
    }
    @Test func nonzeroCompressionFlagsAndHintGrowthUseExactCodec() throws {
        let compressed = literalDCL(one)
        let packet = header(hint: 1) + block(compressed, indicator: 2)
        #expect(try LegacyCompactPostingsReader.decodePacket(packet, expectedHitCount: 1) == LegacyCompactPostingsReader.decodeNumericPayload(one, expectedHitCount: 1))
        #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.decodePacket(packet, expectedHitCount: 1, limits: .init(maximumDecodedBytes: 14)) }
        #expect(throws: LegacyCompactPostingsError.decompressionFailed(-102)) { try LegacyCompactPostingsReader.decodePacket(header() + block(compressed + Data([0]), indicator: 1), expectedHitCount: 1) }
    }
    @Test func mixedCompressedRawBlocksComposeWithoutPartialResults() throws {
        let first = Data(one.prefix(7)), second = Data(one.dropFirst(7))
        let packet = header(hint: 1) + block(literalDCL(first), indicator: 255, last: false) + block(second)
        #expect(try LegacyCompactPostingsReader.decodePacket(packet, expectedHitCount: 1).groups[0].articleBits == 7)
        #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.decodePacket(packet, expectedHitCount: 1, limits: .init(maximumBlocks: 1)) }
        #expect(throws: LegacyCompactPostingsError.decompressionFailed(-1)) { try LegacyCompactPostingsReader.decodePacket(header() + block(Data([2, 4, 255, 255]), indicator: 1), expectedHitCount: 1) }
    }
    @Test func packetFramingTruncationModesAndLastFlagAreChecked() {
        let packet = header() + block(one)
        for count in 0..<packet.count {
            #expect(throws: (any Error).self) { try LegacyCompactPostingsReader.decodePacket(Data(packet.prefix(count)), expectedHitCount: 1) }
        }
        #expect(throws: LegacyCompactPostingsError.unsupportedStream(external: 2, mode: 1)) { try LegacyCompactPostingsReader.decodePacket(le16(2) + Data(packet.dropFirst(2)), expectedHitCount: 1) }
        #expect(throws: LegacyCompactPostingsError.invalidPacket) { try LegacyCompactPostingsReader.decodePacket(header(hint: 0) + block(one), expectedHitCount: 1) }
        #expect(throws: LegacyCompactPostingsError.invalidPacket) { try LegacyCompactPostingsReader.decodePacket(header() + block(one, last: false), expectedHitCount: 1) }
        #expect(throws: LegacyCompactPostingsError.invalidPacket) { try LegacyCompactPostingsReader.decodePacket(header() + Data([0]) + le16(0x8000), expectedHitCount: 1) }
        #expect(throws: LegacyCompactPostingsError.trailingData) { try LegacyCompactPostingsReader.decodePacket(packet + Data([0]), expectedHitCount: 1) }
    }
    @Test func fiveAndSevenByteBranchesAreDiscriminatingNegativeControls() {
        #expect(throws: LegacyPostingsError.invalidNumericPayload) { try LegacyPostingsReader.decodeNumericPayload(one, expectedHitCount: 1) }
        #expect(throws: LegacyCompactPostingsError.trailingData) { try LegacyCompactPostingsReader.decodeNumericPayload(one + le16(9), expectedHitCount: 1) }
    }
    @Test func explicitParentAndRowSelectionPreservesKeysAndSourceFiles() throws {
        try withPair { lsf, lix in
            let before = try Data(contentsOf: lix)
            let first = try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 1)
            let second = try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 1, dictionaryRow: 0)
            #expect(first.dictionaryKeyBytes == Data([0x02, 0x5a, 0]) && first.indexInfoWord == 0xffff)
            #expect(second.dictionaryKeyBytes == Data([0, 0x4f, 0x77, 0x6e, 0]) && second.indexInfoWord == 7)
            #expect(first.parentFileOffset < second.parentFileOffset && first.postings.groups[0].articleBits == .max)
            #expect(second.postings.leadingMetadataWord == 99 && second.postings.hitCount == 1)
            #expect(try Data(contentsOf: lix) == before)
            #expect(throws: LegacyCompactPostingsError.indexOrdinalNotFound(2, available: 2)) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 2, dictionaryRow: 0) }
            #expect(throws: LegacyCompactPostingsError.dictionaryRowNotFound(-1)) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: -1) }
        }
    }
    @Test func missingWIDXNeverFallsBackToBWDX() throws {
        try withPair(family: "BWDX") { lsf, lix in
            #expect(throws: LegacyCompactPostingsError.indexOrdinalNotFound(0, available: 0)) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
    }
    @Test func pairIdentityFailuresRemainTyped() throws {
        try withPair(mismatch: true) { lsf, lix in
            #expect(throws: LegacyCompactPostingsError.mismatchedPair) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
        try withPair(noIdentifier: true) { lsf, lix in
            #expect(throws: LegacyCompactPostingsError.pairIdentifiersUnavailable) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
    }
    @Test func childFramingDoesNotBorrowAnotherParentsTables() throws {
        try withPair(missingInfo: true) { lsf, lix in
            #expect(throws: LegacyCompactPostingsError.invalidIndex("WIDX/info")) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
        try withPair(duplicateInfo: true) { lsf, lix in
            #expect(throws: LegacyCompactPostingsError.invalidIndex("WIDX/info")) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
        try withPair { lsf, lix in
            var bytes = try Data(contentsOf: lix)
            let pair = try LegacyResourceReader.inspect(lsfURL: lsf, lixURL: lix)
            let info = pair.lix!.blocks.first { $0.tag == "info" }!
            bytes[Int(info.offset) - 8] ^= 1; try bytes.write(to: lix)
            #expect(throws: LegacyCompactPostingsError.invalidIndex("info")) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
    }
    @Test func contradictoryOffsetsAndDeclaredCountsFailBeforeLargeReads() throws {
        try withPair(badOffset: true) { lsf, lix in
            #expect(throws: LegacyCompactPostingsError.invalidIndex("WIDX/row offsets")) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
        try withPair(overlargeRows: true) { lsf, lix in
            #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
        try withPair(overlargeHits: true) { lsf, lix in
            #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0) }
        }
    }
    @Test func callerLimitsPrecedeIOAndSelectedKeyPacketAllocations() throws {
        let missing = URL(fileURLWithPath: "/own-missing")
        #expect(throws: LegacyCompactPostingsError.invalidLimits) { try LegacyCompactPostingsReader.readTerm(lsfURL: missing, lixURL: missing, indexOrdinal: 0, dictionaryRow: 0, limits: .init(maximumIndices: 0)) }
        try withPair { lsf, lix in
            for limit in [LegacyCompactPostingsLimits(maximumIndices: 1), .init(maximumDictionaryRows: 1),
                          .init(maximumKeyBytes: 1), .init(maximumPacketBytes: 9)] {
                #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.readTerm(lsfURL: lsf, lixURL: lix, indexOrdinal: 0, dictionaryRow: 0, limits: limit) }
            }
        }
    }
    @Test func signedPositiveBoundaryAndUInt32CountOverflowStaySeparate() throws {
        let records = Array(repeating: (UInt32.max, UInt8.max), count: Int(Int16.max))
        let raw = numeric(metadata: 1, groups: [(0, records)])
        #expect(try LegacyCompactPostingsReader.decodeNumericPayload(raw, expectedHitCount: UInt32(Int16.max)).hitCount == Int(Int16.max))
        #expect(throws: LegacyCompactPostingsError.limitExceeded) { try LegacyCompactPostingsReader.decodeNumericPayload(raw, expectedHitCount: .max) }
    }
    @Test func cancelledTaskCannotReturnPartialValuesOrStartFileIO() async throws {
        let raw = one
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try LegacyCompactPostingsReader.decodeNumericPayload(raw, expectedHitCount: 1)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled scalar decoder returned a value") } catch is CancellationError {}
        let fileTask = Task {
            while !Task.isCancelled { await Task.yield() }
            let missing = URL(fileURLWithPath: "/own-missing")
            return try LegacyCompactPostingsReader.readTerm(lsfURL: missing, lixURL: missing, indexOrdinal: 0, dictionaryRow: 0)
        }
        fileTask.cancel()
        do { _ = try await fileTask.value; Issue.record("Cancelled file reader returned a value") } catch is CancellationError {}
    }

    private func numeric(metadata: UInt32, groups: [(UInt32, [(UInt32, UInt8)])]) -> Data {
        var bytes = le32(metadata)
        for (article, postings) in groups {
            bytes.append(le32(article)); bytes.append(le16(UInt16(postings.count)))
            for (position, extent) in postings { bytes.append(le32(position)); bytes.append(extent) }
        }
        return bytes
    }
    private func header(hint: UInt16 = 8192) -> Data { le16(0) + le16(1) + le16(hint) }
    private func block(_ data: Data, indicator: UInt8 = 0, last: Bool = true) -> Data {
        Data([indicator]) + le16(UInt16(data.count) | (last ? 0x8000 : 0)) + data
    }
    private func literalDCL(_ data: Data) -> Data {
        var bits: [UInt8] = []
        for byte in data { bits.append(0); bits.append(contentsOf: (0..<8).map { (byte >> $0) & 1 }) }
        bits.append(contentsOf: [1] + Array(repeating: 0, count: 7) + Array(repeating: 1, count: 8))
        var output = Data([0, 4])
        for at in stride(from: 0, to: bits.count, by: 8) {
            var byte: UInt8 = 0
            for bit in 0..<8 where at + bit < bits.count { byte |= bits[at + bit] << bit }
            output.append(byte)
        }
        return output
    }
    private struct Chunk {
        let tag: String; let bytes: Data; let children: [Chunk]
        init(_ tag: String, _ bytes: Data = Data(), children: [Chunk] = []) { self.tag = tag; self.bytes = bytes; self.children = children }
        var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
        var size: Int { children.isEmpty ? bytes.count : children.reduce(0) { $0 + 8 + $1.size } }
    }
    private func withPair(family: String = "WIDX", mismatch: Bool = false, noIdentifier: Bool = false,
                          missingInfo: Bool = false, duplicateInfo: Bool = false, badOffset: Bool = false,
                          overlargeRows: Bool = false, overlargeHits: Bool = false, _ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lsf = directory.appendingPathComponent("Own.LSF"), lix = directory.appendingPathComponent("Own.LIX")
        let identity = Data([1, 0, 0, 0, 3, 0, 0, 0, 0x35, 0])
        try container("GTTL", noIdentifier ? [] : [Chunk("bkid", identity)]).write(to: lsf)
        let first = header(hint: 1) + block(literalDCL(one), indicator: 2)
        let second = header() + block(numeric(metadata: 7, groups: [(.max, [(.max, 255)])]))
        let records = le32(0) + le32(0) + le32(overlargeHits ? .max : 1) +
            le32(5) + le32(badOffset ? .max : UInt32(first.count)) + le32(1)
        let info = Chunk("info", le16(0) + le32(overlargeRows ? .max : 2) + le16(.max))
        var children = [Chunk("hlst", records), Chunk("klst", Data([0, 0x4f, 0x77, 0x6e, 0, 2, 0x5a, 0])), Chunk("hits", first + second)]
        if !missingInfo { children.insert(info, at: 0) }
        if duplicateInfo { children.append(info) }
        let other = Chunk(family, children: [Chunk("info", le16(0) + le32(2) + le16(7)), Chunk("hlst", records),
            Chunk("klst", Data([0, 0x4f, 0x77, 0x6e, 0, 2, 0x5a, 0])), Chunk("hits", first + second)])
        let indexID = le16(1) + (mismatch ? Data(repeating: 0, count: 10) : identity)
        try container("BIDX", [Chunk("bkid", indexID), Chunk(family, children: children), other]).write(to: lix)
        try body(lsf, lix)
    }
    private func container(_ kind: String, _ chunks: [Chunk]) -> Data {
        let directorySize = 18 + chunks.reduce(0) { $0 + $1.count } * 18
        var prefix = Data(repeating: 0, count: 44)
        prefix.replaceSubrange(0..<4, with: Data("LSFF".utf8)); prefix.replaceSubrange(8..<12, with: Data(kind.utf8))
        prefix.replaceSubrange(36..<40, with: Data("pcr ".utf8)); prefix.replaceSubrange(40..<44, with: le32(UInt32(directorySize)))
        var directory = Data("LSFF\(kind)".utf8) + Data(repeating: 0, count: 10), payload = Data()
        func emit(_ chunk: Chunk, at offset: Int) -> Data {
            directory.append(Data(chunk.tag.utf8) + le32(0) + le32(UInt32(chunk.size)) + le32(UInt32(offset + 8)) + le16(UInt16(chunk.children.count)))
            var output = Data(chunk.tag.utf8) + le32(UInt32(chunk.size))
            if chunk.children.isEmpty { output.append(chunk.bytes) }
            else { for child in chunk.children { output.append(emit(child, at: offset + output.count)) } }
            return output
        }
        for chunk in chunks { payload.append(emit(chunk, at: 44 + directorySize + payload.count)) }
        var result = prefix + directory + payload; result.replaceSubrange(4..<8, with: le32(UInt32(result.count - 8)))
        return result
    }
    private func le16(_ word: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8)]) }
    private func le32(_ word: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }) }
}
