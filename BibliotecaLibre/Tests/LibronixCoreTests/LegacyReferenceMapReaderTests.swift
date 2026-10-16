import Foundation
import Testing
@testable import LibronixCore

struct LegacyReferenceMapReaderTests {
    @Test func retainsEveryPackedFieldRawByteAndSourceOrder() throws {
        let first = row(65535, UInt32.max, 0x80000000, 3, UInt32.max)
        let second = row(7, 9, 11, 1, 0)
        let map = try LegacyReferenceMapReader.decodeTable(info: info(2), records: first + second)
        #expect(map.rawInfoBytes == info(2) && map.declaredRowCount == 2 && map.infoHeaderWord == 0)
        #expect(map.rows.map(\.referenceKeyBits) == [65535, 7])
        #expect(map.rows.map(\.recordOffset) == [0, 18])
        #expect(map.rows[0].rawBytes == first && map.rows[1].rawBytes == second)
        #expect(map.rows[0].startArticleBits == UInt32.max)
        #expect(map.rows[0].startPositionBits == 0x80000000)
        #expect(map.rows[0].endArticleBits == 3 && map.rows[0].endPositionBits == UInt32.max)
        #expect(map.recordPayloadFileOffset == nil)
        #expect(try map.lookup(referenceKey: 7).row == 1)
    }

    @Test func slicedDataWithNonzeroIndicesKeepsPackedAlignment() throws {
        let expected = row(32768, 5, 6, 7, 8)
        let framed = Data([99]) + expected + Data([88])
        let records = framed.dropFirst().dropLast()
        let header = (Data([99]) + info(1)).dropFirst()
        let map = try LegacyReferenceMapReader.decodeTable(info: header, records: records)
        #expect(map.rows[0].rawBytes == expected)
        #expect(map.rows[0].referenceKeyBits == 32768 && map.rows[0].endPositionBits == 8)
    }

    @Test func emptyTableHasTypedMissingLookupWithoutInventingContext() throws {
        let map = try LegacyReferenceMapReader.decodeTable(info: info(0), records: Data(),
            limits: .init(maximumRows: 0, maximumRecordBytes: 0))
        #expect(map.rows.isEmpty && map.declaredRowCount == 0)
        #expect(throws: LegacyReferenceMapError.missingReferenceKey(0)) { try map.lookup(referenceKey: 0) }
    }

    @Test func duplicateKeysRetainBothRowsAndRefuseUnprovedTieChoice() throws {
        let first = row(9, 1, 2, 3, 4), second = row(9, 5, 6, 7, 8)
        let map = try LegacyReferenceMapReader.decodeTable(info: info(2), records: first + second)
        #expect(map.rows.map(\.rawBytes) == [first, second])
        #expect(throws: LegacyReferenceMapError.ambiguousReferenceKey(9, matches: 2)) {
            try map.lookup(referenceKey: 9)
        }
    }

    @Test func preservesCoordinateChannelsWithoutOrderingOrContainmentRules() throws {
        let map = try LegacyReferenceMapReader.decodeTable(info: info(1),
            records: row(1, UInt32.max, UInt32.max, 0, 0))
        #expect(map.rows[0].startArticleBits == UInt32.max && map.rows[0].endArticleBits == 0)
        let projection = try map.project(referenceKey: 1, articleBits: 0, positionBits: 20, extentBits: UInt32.max)
        #expect(projection.articleDeltaBits == 1 && projection.positionBits == 20)
        #expect(projection.extentBits == UInt32.max)
    }

    @Test func everyTruncatedHeaderAndPackedRowFailsWithoutPartialResults() {
        let records = row(1, 2, 3, 4, 5)
        for prefix in 0..<6 {
            #expect(throws: LegacyReferenceMapError.invalidTable("RTAX/info")) {
                try LegacyReferenceMapReader.decodeTable(info: Data(info(1).prefix(prefix)), records: records)
            }
        }
        for prefix in 0..<18 {
            #expect(throws: LegacyReferenceMapError.invalidTable("RTAX/hlst")) {
                try LegacyReferenceMapReader.decodeTable(info: info(1), records: Data(records.prefix(prefix)))
            }
        }
    }

    @Test func countMismatchTailsAndUnsupportedHeaderAreExplicit() {
        let records = row(1, 2, 3, 4, 5)
        for count in [UInt32(0), UInt32(2)] {
            #expect(throws: LegacyReferenceMapError.invalidTable("RTAX/hlst")) {
                try LegacyReferenceMapReader.decodeTable(info: info(count), records: records)
            }
        }
        #expect(throws: LegacyReferenceMapError.invalidTable("RTAX/hlst")) {
            try LegacyReferenceMapReader.decodeTable(info: info(1), records: records + Data([0]))
        }
        #expect(throws: LegacyReferenceMapError.invalidTable("RTAX/info")) {
            try LegacyReferenceMapReader.decodeTable(info: info(1) + Data([0]), records: records)
        }
        #expect(throws: LegacyReferenceMapError.unsupportedInfoHeaderWord(65535)) {
            try LegacyReferenceMapReader.decodeTable(info: le16(65535) + le32(1), records: records)
        }
    }

    @Test func budgetsRejectCountsAndBytesBeforeAllocation() {
        let records = row(1, 2, 3, 4, 5)
        #expect(throws: LegacyReferenceMapError.limitExceeded) {
            try LegacyReferenceMapReader.decodeTable(info: info(UInt32.max), records: Data())
        }
        #expect(throws: LegacyReferenceMapError.limitExceeded) {
            try LegacyReferenceMapReader.decodeTable(info: info(1), records: records, limits: .init(maximumRows: 0))
        }
        #expect(throws: LegacyReferenceMapError.limitExceeded) {
            try LegacyReferenceMapReader.decodeTable(info: info(1), records: records, limits: .init(maximumRecordBytes: 17))
        }
        #expect(throws: LegacyReferenceMapError.invalidLimits) {
            try LegacyReferenceMapReader.decodeTable(info: info(0), records: Data(), limits: .init(maximumRows: -1))
        }
        #expect(throws: LegacyReferenceMapError.invalidLimits) {
            try LegacyReferenceMapReader.decodeTable(info: info(0), records: Data(), limits: .init(maximumRecordBytes: Int.max))
        }
    }

    @Test func invalidLimitsPrecedeFilesystemAccess() {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: LegacyReferenceMapError.invalidLimits) {
            try LegacyReferenceMapReader.read(lsfURL: absent, lixURL: absent, limits: .init(maximumRows: Int.max))
        }
    }

    @Test func checkedPairRetainsPayloadOffsetsAndOriginalSyntheticFiles() throws {
        try withPair { lsf, lix in
            let beforeLSF = try Data(contentsOf: lsf), beforeLIX = try Data(contentsOf: lix)
            let map = try LegacyReferenceMapReader.read(lsfURL: lsf, lixURL: lix)
            let metadata = try LegacyResourceReader.inspect(lsfURL: lsf, lixURL: lix)
            let parent = try #require(metadata.lix?.blocks.first(where: { $0.tag == "RTAX" }))
            let records = metadata.lix?.blocks.first(where: { $0.tag == "hlst" && $0.offset >= parent.offset })
            #expect(map.recordPayloadFileOffset == records?.offset)
            #expect(map.rows[0].rawBytes == row(9, 5, 80, 5, 100))
            #expect(try Data(contentsOf: lsf) == beforeLSF && Data(contentsOf: lix) == beforeLIX)
        }
    }

    @Test func pairIdentityAndReferenceParentSelectionAreChecked() throws {
        try withPair(mismatch: true) { lsf, lix in
            #expect(throws: LegacyReferenceMapError.mismatchedPair) { try LegacyReferenceMapReader.read(lsfURL: lsf, lixURL: lix) }
        }
        try withPair(omitIdentifier: true) { lsf, lix in
            #expect(throws: LegacyReferenceMapError.pairIdentifiersUnavailable) { try LegacyReferenceMapReader.read(lsfURL: lsf, lixURL: lix) }
        }
        try withPair(parentCopies: 0) { lsf, lix in
            #expect(throws: LegacyReferenceMapError.missingReferenceMap) { try LegacyReferenceMapReader.read(lsfURL: lsf, lixURL: lix) }
        }
        try withPair(parentCopies: 2) { lsf, lix in
            #expect(throws: LegacyReferenceMapError.ambiguousReferenceMap) { try LegacyReferenceMapReader.read(lsfURL: lsf, lixURL: lix) }
        }
    }

    @Test func missingAndAmbiguousChildrenDoNotUseOtherIndexTables() throws {
        let record = row(9, 5, 80, 5, 100)
        for children in [[Chunk("info", info(1))],
                         [Chunk("info", info(1)), Chunk("hlst", record), Chunk("hlst", record)]] {
            try withPair(children: children) { lsf, lix in
                #expect(throws: LegacyReferenceMapError.invalidTable("RTAX/hlst")) {
                    try LegacyReferenceMapReader.read(lsfURL: lsf, lixURL: lix)
                }
            }
        }
    }

    @Test func directoryAndPhysicalChunkHeadersMustAgree() throws {
        for tag in ["RTAX", "info", "hlst"] {
            try withPair { lsf, lix in
                let pair = try LegacyResourceReader.inspect(lsfURL: lsf, lixURL: lix)
                let parent = try #require(pair.lix?.blocks.first(where: { $0.tag == "RTAX" }))
                let offset = try #require(pair.lix?.blocks.first(where: {
                    $0.tag == tag && $0.offset >= parent.offset
                })?.offset)
                var bytes = try Data(contentsOf: lix)
                bytes.replaceSubrange(Int(offset) - 8..<Int(offset) - 4, with: Data("FAIL".utf8))
                try bytes.write(to: lix)
                #expect(throws: LegacyReferenceMapError.invalidTable(tag)) {
                    try LegacyReferenceMapReader.read(lsfURL: lsf, lixURL: lix)
                }
            }
        }
    }

    @Test func successfulProjectionPreservesStrictGreaterThanBranch() throws {
        let map = try LegacyReferenceMapReader.decodeTable(info: info(1), records: row(9, 6479, 80, 6479, 100))
        for (position, expected) in [(UInt32(93), UInt32(13)), (80, 80), (79, 79)] {
            let projection = try map.project(referenceKey: 9, articleBits: 6479, positionBits: position, extentBits: 15)
            #expect(projection.parentArticleBits == 6479 && projection.parentOriginBits == 80)
            #expect(projection.positionBits == expected && projection.extentBits == 15 && projection.articleDeltaBits == 0)
            #expect(projection.olaSuffix == "::OLA:\(expected).15.0")
        }
    }

    @Test func nextArticleAndDwordWrapDoNotSubtractOriginOrEnforceRange() throws {
        let map = try LegacyReferenceMapReader.decodeTable(info: info(1), records: row(9, 6479, 80, 6479, 85))
        let next = try map.project(referenceKey: 9, articleBits: 6480, positionBits: 93, extentBits: 255)
        #expect(next.olaSuffix == "::OLA:93.255.1")
        let wrapping = try LegacyReferenceMapReader.decodeTable(info: info(1), records: row(9, UInt32.max, 80, 0, 0))
        let wrapped = try wrapping.project(referenceKey: 9, articleBits: 0, positionBits: UInt32.max, extentBits: UInt32.max)
        #expect(wrapped.articleDeltaBits == 1 && wrapped.positionBits == UInt32.max && wrapped.extentBits == UInt32.max)
    }

    @Test func projectionRequiresTypedUnambiguousLookupAndNeverDefaults() throws {
        let map = try LegacyReferenceMapReader.decodeTable(info: info(2), records: row(9, 1, 2, 3, 4) + row(9, 5, 6, 7, 8))
        #expect(throws: LegacyReferenceMapError.missingReferenceKey(10)) {
            try map.project(referenceKey: 10, articleBits: 1, positionBits: 2, extentBits: 3)
        }
        #expect(throws: LegacyReferenceMapError.ambiguousReferenceKey(9, matches: 2)) {
            try map.project(referenceKey: 9, articleBits: 1, positionBits: 2, extentBits: 3)
        }
    }

    @Test func cancelledDecodingProducesNoPartialMap() async {
        let header = info(1), records = row(9, 1, 2, 3, 4)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try LegacyReferenceMapReader.decodeTable(info: header, records: records)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
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

    private func withPair(mismatch: Bool = false, omitIdentifier: Bool = false, parentCopies: Int = 1,
                          children: [Chunk]? = nil, _ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lsf = directory.appendingPathComponent("Own.LSF"), lix = directory.appendingPathComponent("Own.LIX")
        let identifier = Data([1, 0, 0, 0, 3, 0, 0, 0, 53, 0])
        try container("GTTL", omitIdentifier ? [] : [Chunk("bkid", identifier)]).write(to: lsf)
        let tableChildren = children ?? [Chunk("info", info(1)), Chunk("hlst", row(9, 5, 80, 5, 100))]
        let parents = (0..<parentCopies).map { _ in Chunk("RTAX", children: tableChildren) }
        let indexID = le16(1) + (mismatch ? Data(repeating: 0, count: 10) : identifier)
        // Unrelated info/hlst children cannot replace a missing RTAX child.
        let other = Chunk("WIDX", children: [Chunk("info", Data([0])), Chunk("hlst", Data([0]))])
        try container("BIDX", [Chunk("bkid", indexID), other] + parents).write(to: lix)
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

    private func info(_ count: UInt32) -> Data { le16(0) + le32(count) }
    private func row(_ key: UInt16, _ start: UInt32, _ position: UInt32, _ end: UInt32, _ endPosition: UInt32) -> Data {
        le16(key) + le32(start) + le32(position) + le32(end) + le32(endPosition)
    }
    private func le16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
    private func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
}
