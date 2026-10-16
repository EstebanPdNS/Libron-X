import Foundation
import Testing
@testable import LibronixCore

struct LegacyDictionaryReaderTests {
    @Test func pageSelectorsAreHighBytesRatherThanUnicodeEncodings() throws {
        let cases: [(Data, [UInt16])] = [
            (Data([0, 0]), []),
            (Data([0, 65, 90, 0]), [65, 90]),
            (Data([2, 90, 0]), [0x025a]),
            (Data([0x41, 0x62, 0]), [0x4162]),
            (Data([0, 0xc3, 0xa9, 0]), [0x00c3, 0x00a9])
        ]
        for (bytes, units) in cases {
            let key = try LegacyDictionaryReader.decodeKey(bytes)
            #expect(key.units == units)
            #expect(key.selector == bytes.first)
            #expect(key.consumedByteCount == bytes.count)
        }
    }

    @Test func fullUnitKeysPreserveLowZeroAndSurrogates() throws {
        let bytes = Data([0xf0, 0, 1, 0, 0xd8, 0, 0xdc, 0xff, 0xff, 0, 0])
        let key = try LegacyDictionaryReader.decodeKey(bytes)
        #expect(key.units == [0x0100, 0xd800, 0xdc00, 0xffff])
        #expect(key.consumedByteCount == 11)
        let unpaired = try LegacyDictionaryReader.decodeKey(Data([0xf0, 1, 0xd8, 0, 0]))
        #expect(unpaired.units == [0xd801])
        #expect(try LegacyDictionaryReader.decodeKey(Data([0xf0, 0, 0])).units.isEmpty)
    }

    @Test func consumptionStopsAtTerminatorAndRetainsRowPaddingCount() throws {
        for (bytes, consumed) in [(Data([0, 65, 0, 0, 0, 0, 0]), 3),
                                 (Data([0xf0, 65, 0, 0, 0, 0x33, 0x44]), 5)] {
            let key = try LegacyDictionaryReader.decodeKey(bytes)
            #expect(key.units == [65])
            #expect(key.consumedByteCount == consumed)
            #expect(key.storedByteCount == bytes.count)
        }
    }

    @Test func incompleteKeyFramingHasNoPartialSuccess() {
        for bytes in [Data(), Data([0]), Data([0, 65]), Data([0xf0]),
                      Data([0xf0, 65]), Data([0xf0, 65, 0]), Data([0xf0, 65, 0, 0])] {
            #expect(throws: LegacyDictionaryError.missingTerminator) {
                try LegacyDictionaryReader.decodeKey(bytes)
            }
        }
    }

    @Test func unitAndStoredByteBudgetsIncludeExactBoundary() throws {
        let one = Data([0, 65, 0])
        #expect(try LegacyDictionaryReader.decodeKey(one, limits: .init(maximumStoredKeyBytes: 3, maximumKeyUnits: 1)).units == [65])
        #expect(throws: LegacyDictionaryError.limitExceeded) {
            try LegacyDictionaryReader.decodeKey(one, limits: .init(maximumStoredKeyBytes: 2))
        }
        #expect(throws: LegacyDictionaryError.limitExceeded) {
            try LegacyDictionaryReader.decodeKey(one, limits: .init(maximumKeyUnits: 0))
        }
        #expect(try LegacyDictionaryReader.decodeKey(Data([0, 0]), limits: .init(maximumKeyUnits: 0)).units.isEmpty)
        #expect(throws: LegacyDictionaryError.invalidLimits) {
            try LegacyDictionaryReader.decodeKey(one, limits: .init(maximumStoredKeyBytes: Int.max))
        }
        #expect(throws: LegacyDictionaryError.invalidLimits) {
            try LegacyDictionaryReader.decodeKey(one, limits: .init(maximumTotalUnits: -1))
        }
    }

    @Test func exactScanHandlesUnsortedKeysAndPreservesDuplicateRows() throws {
        // Deliberate ordering inversion and duplicate keys encoded by different branches.
        try withPair(keys: [page([122]), page([65]), full([65]), page([98])]) { (lsf: URL, lix: URL) throws -> Void in
            let before = try Data(contentsOf: lix)
            let found = try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65])
            #expect(found.scannedRows == 4 && found.decodedUnitCount == 4)
            #expect(found.matches.map(\.dictionaryRow) == [1, 2])
            #expect(found.matches.map(\.key.selector) == [0, 0xf0])
            #expect(found.matches.map(\.expectedHitCount) == [1, 1])
            for match in found.matches {
                let entry = try LegacyPostingsReader.readBodyTerm(lsfURL: lsf, lixURL: lix, dictionaryRow: match.dictionaryRow)
                #expect(entry.packetFileOffset == match.packetFileOffset)
                #expect(entry.packetByteCount == match.packetByteCount)
                #expect(entry.postings.groups[0].articleBits == UInt32(match.dictionaryRow + 7))
            }
            #expect(try Data(contentsOf: lix) == before)
        }
    }

    @Test func literalCaseAccentsAndCanonicalFormsAreNeverFolded() throws {
        try withPair(keys: [page([65]), page([97]), full([0xe9]), full([101, 0x301])]) { (lsf: URL, lix: URL) throws -> Void in
            for (units, row) in [([UInt16(65)], 0), ([97], 1), ([0xe9], 2), ([101, 0x301], 3)] {
                #expect(try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: units).matches.map(\.dictionaryRow) == [row])
            }
            #expect(try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [69]).matches.isEmpty)
        }
    }

    @Test func emptyAndPaddedFinalRowsAreSelectable() throws {
        try withPair(keys: [page([]), page([90]) + Data(repeating: 0, count: 4)]) { (lsf: URL, lix: URL) throws -> Void in
            #expect(try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: []).matches.map(\.dictionaryRow) == [0])
            let last = try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [90])
            #expect(last.matches[0].dictionaryRow == 1)
            #expect(last.matches[0].key.consumedByteCount == 3)
            #expect(last.matches[0].key.storedByteCount == 7)
        }
        try withPair(keys: []) { (lsf: URL, lix: URL) throws -> Void in
            let found = try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [90])
            #expect(found.scannedRows == 0 && found.scannedKeyBytes == 0 && found.matches.isEmpty)
        }
    }

    @Test func allRowsAreCheckedEvenAfterTheFirstMatch() throws {
        try withPair(keys: [page([65]), Data([0, 66])]) { (lsf: URL, lix: URL) throws -> Void in
            #expect(throws: LegacyDictionaryError.missingTerminator) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65])
            }
        }
        try withPair(keys: [page([65]), page([66])], wrongFinalOffset: true) { (lsf: URL, lix: URL) throws -> Void in
            #expect(throws: LegacyPostingsError.invalidIndex("BWDX/row offsets")) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65])
            }
        }
    }

    @Test func wholeScanBudgetsAndLiteralGuardsFailAtomically() throws {
        try withPair(keys: [page([65]), page([65])]) { (lsf: URL, lix: URL) throws -> Void in
            #expect(throws: LegacyDictionaryError.limitExceeded) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65], limits: .init(maximumMatches: 1))
            }
            #expect(throws: LegacyDictionaryError.limitExceeded) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [66], limits: .init(maximumTotalUnits: 1))
            }
            #expect(throws: LegacyDictionaryError.limitExceeded) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [66], limits: .init(maximumKeyTableBytes: 5))
            }
            #expect(throws: LegacyPostingsError.limitExceeded) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65], limits: .init(maximumRows: 1))
            }
            #expect(throws: LegacyDictionaryError.invalidLiteral) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [0])
            }
            #expect(throws: LegacyDictionaryError.limitExceeded) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65], limits: .init(maximumKeyUnits: 0))
            }
        }
    }

    @Test func pairIdentityAndUnsupportedIndexVersionRemainChecked() throws {
        try withPair(keys: [page([65])], mismatch: true) { (lsf: URL, lix: URL) throws -> Void in
            #expect(throws: LegacyPostingsError.mismatchedPair) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65])
            }
        }
        try withPair(keys: [page([65])], version: 1) { (lsf: URL, lix: URL) throws -> Void in
            #expect(throws: LegacyPostingsError.invalidIndex("BWDX/version")) {
                try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65])
            }
        }
    }

    @Test func cancellableScanHonorsTaskCancellation() async throws {
        try await withAsyncPair { lsf, lix in
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try LegacyDictionaryReader.lookupExact(lsfURL: lsf, lixURL: lix, units: [65])
            }
            do { _ = try await task.value; Issue.record("Cancelled lookup unexpectedly succeeded") }
            catch is CancellationError { }
        }
    }

    private func page(_ units: [UInt8]) -> Data { Data([0] + units + [0]) }
    private func full(_ units: [UInt16]) -> Data {
        Data([0xf0]) + units.reduce(into: Data()) { $0.append(le16($1)) } + le16(0)
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

    private func makePair(in directory: URL, keys: [Data], wrongFinalOffset: Bool = false,
                          mismatch: Bool = false, version: UInt16 = 0) throws -> (URL, URL) {
        let lsf = directory.appendingPathComponent("Own.LSF"), lix = directory.appendingPathComponent("Own.LIX")
        let identifier = Data([1, 0, 0, 0, 3, 0, 0, 0, 53, 0])
        try container("GTTL", [Chunk("bkid", identifier)]).write(to: lsf)
        var keyBytes = Data(), records = Data(), packets = Data()
        for (row, key) in keys.enumerated() {
            records.append(le32(UInt32(keyBytes.count)))
            records.append(le32(wrongFinalOffset && row == keys.count - 1 ? UInt32.max : UInt32(packets.count)))
            records.append(le32(1))
            keyBytes.append(key)
            let payload = le32(0) + le32(UInt32(row + 7)) + le16(1) + le32(10) + Data([5]) + le16(6)
            packets.append(le16(0) + le16(1) + le16(8192) + Data([0]) + le16(UInt16(payload.count) | 0x8000) + payload)
        }
        let body = Chunk("BWDX", children: [Chunk("info", le16(version) + le32(UInt32(keys.count)) + le16(1)),
            Chunk("klst", keyBytes), Chunk("hlst", records), Chunk("hits", packets)])
        let indexID = le16(1) + (mismatch ? Data(repeating: 0, count: 10) : identifier)
        try container("BIDX", [Chunk("bkid", indexID), body]).write(to: lix)
        return (lsf, lix)
    }

    private func withPair(keys: [Data], wrongFinalOffset: Bool = false, mismatch: Bool = false,
                          version: UInt16 = 0, _ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (lsf, lix) = try makePair(in: directory, keys: keys, wrongFinalOffset: wrongFinalOffset,
                                     mismatch: mismatch, version: version)
        try body(lsf, lix)
    }

    private func withAsyncPair(_ body: (URL, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (lsf, lix) = try makePair(in: directory, keys: [page([65])])
        try await body(lsf, lix)
    }

    private func container(_ kind: String, _ chunks: [Chunk]) -> Data {
        let directorySize = 18 + chunks.reduce(0) { $0 + $1.count } * 18
        var prefix = Data(repeating: 0, count: 44)
        prefix.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        prefix.replaceSubrange(8..<12, with: Data(kind.utf8))
        prefix.replaceSubrange(36..<40, with: Data("pcr ".utf8))
        prefix.replaceSubrange(40..<44, with: le32(UInt32(directorySize)))
        var directory = Data("LSFF\(kind)".utf8) + Data(repeating: 0, count: 10), payload = Data()
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
