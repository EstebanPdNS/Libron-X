import Foundation
import Testing
@testable import LibronixCore

struct LegacyLanguageProfileReaderTests {
    @Test func preservesUnversionedProfileRawStringsAndFields() throws {
        let bytes = profile(version: nil, module: Data([0xff, 0, 0x81]))
        let value = try LegacyLanguageProfileReader.decodeProfile(bytes)
        #expect(value.serializedVersion == nil)
        #expect(value.languageIdentifier == 0x1234 && value.unitMapIdentifier == 0x2345)
        #expect(value.word2A == 0xabcd && value.byte2C == 0x89)
        #expect(value.moduleNameBytes == Data([0xff, 0, 0x81]))
        #expect(value.label1CBytes == Data([0xc1]) && value.label20Bytes == Data([0x80, 0xfe]))
        #expect(value.extra24Bytes == nil && value.byte28 == nil)
        #expect(value.callbackNameBytes.count == 7 && value.callbackNameBytes.allSatisfy { $0.isEmpty })
        #expect(value.word0A == 0x4567 && value.phoneticIdentifier == 0x6789 && value.rawPacket == bytes)
    }

    @Test func preservesVersionZeroAndPositiveVersionBranches() throws {
        let zero = try LegacyLanguageProfileReader.decodeProfile(profile(version: 0))
        let positive = try LegacyLanguageProfileReader.decodeProfile(profile(version: 100))
        #expect(zero.serializedVersion == 0 && zero.extra24Bytes == nil)
        #expect(positive.serializedVersion == 100 && positive.extra24Bytes == Data([0x00, 0xff]))
        #expect(positive.byte28 == 0xfa)
    }

    @Test func normalizesSlicedDataBeforeReadingOffsets() throws {
        let raw = profile(version: 1)
        let sliced = (Data([0xee]) + raw).dropFirst()
        #expect(sliced.startIndex == 1)
        #expect(try LegacyLanguageProfileReader.decodeProfile(sliced).rawPacket == raw)
        let table = collation(rows: [[1, 0, 5, 6, 7]])
        #expect(try LegacyLanguageProfileReader.decodeCollation((Data([0xee]) + table).dropFirst()).rawPacket == table)
    }

    @Test func rejectsSignedLengthsTruncationAndTails() throws {
        var negative = profile(version: 1); negative[9] = 0xff; negative[10] = 0xff
        #expect(throws: LegacyLanguageError.negativeStringLength) { try LegacyLanguageProfileReader.decodeProfile(negative) }
        #expect(throws: LegacyLanguageError.truncatedPacket) { try LegacyLanguageProfileReader.decodeProfile(profile(version: 1).dropLast()) }
        #expect(throws: LegacyLanguageError.packetTail) { try LegacyLanguageProfileReader.decodeProfile(profile(version: 1) + Data([0])) }
        #expect(throws: LegacyLanguageError.limitExceeded) { try LegacyLanguageProfileReader.decodeProfile(profile(version: 1), limits: .init(maximumStringBytes: 1)) }
    }

    @Test func collationKeepsDuplicatesContractionsAndEveryField() throws {
        let raw = collation(rows: [[10, 11, 0xffff, 0x8000, 0xabcd], [10, 0, 8, 9, 10]])
        let table = try LegacyLanguageProfileReader.decodeCollation(raw)
        #expect(table.identifier == 0x1234 && table.rows.count == 2 && table.maximumPrimaryWeight == 0xffff)
        #expect(table.rows[0].secondUnit == 11 && table.rows[0].modifier06 == 0x8000 && table.rows[0].modifier08 == 0xabcd)
        #expect(table.rows[1].primaryWeight == 8 && table.rawPacket == raw)
    }

    @Test func collationRejectsBoundsUnorderedRowsAndTails() {
        #expect(throws: LegacyLanguageError.truncatedPacket) { try LegacyLanguageProfileReader.decodeCollation(Data([0])) }
        #expect(throws: LegacyLanguageError.truncatedPacket) { try LegacyLanguageProfileReader.decodeCollation(collation(rows: [[1, 0, 2, 0, 0]]).dropLast()) }
        #expect(throws: LegacyLanguageError.packetTail) { try LegacyLanguageProfileReader.decodeCollation(collation(rows: []) + Data([0])) }
        #expect(throws: LegacyLanguageError.unorderedCollation) { try LegacyLanguageProfileReader.decodeCollation(collation(rows: [[2, 0, 2, 0, 0], [1, 0, 1, 0, 0]])) }
        #expect(throws: LegacyLanguageError.limitExceeded) { try LegacyLanguageProfileReader.decodeCollation(collation(rows: [[1, 0, 1, 0, 0]]), limits: .init(maximumCollationRows: 0)) }
    }

    @Test func sourceOrderedContainerAndAmbiguousSelection() throws {
        let first = profile(version: nil), table = collation(rows: [])
        let data = try LegacyLanguageProfileReader.decodeContainer(container([("ldat", first), ("other", Data([7])), ("coll", table), ("ldat", first)]))
        #expect(data.directoryRecordCount == 4 && data.profiles.map(\.rawPacket) == [first, first])
        #expect(data.collations.map(\.rawPacket) == [table])
        #expect(throws: LegacyLanguageError.profileSelection(0x1234, matches: 2)) { try data.profile(languageIdentifier: 0x1234) }
        #expect(throws: LegacyLanguageError.profileSelection(7, matches: 0)) { try data.profile(languageIdentifier: 7) }
        #expect(throws: LegacyLanguageError.collationSelection(7, matches: 0)) { try data.collation(identifier: 7) }
    }

    @Test func containerChecksSizeRangesHeadersAndBudgets() throws {
        let good = container([("ldat", profile(version: 1))])
        var bad = good; bad[4] ^= 1
        #expect(throws: LegacyLanguageError.invalidContainer) { try LegacyLanguageProfileReader.decodeContainer(bad) }
        bad = good; bad[40] = 19
        #expect(throws: LegacyLanguageError.invalidDirectory) { try LegacyLanguageProfileReader.decodeContainer(bad) }
        bad = good; bad[80] ^= 1
        #expect(throws: LegacyLanguageError.invalidPhysicalHeader) { try LegacyLanguageProfileReader.decodeContainer(bad) }
        bad = container([("zzzz", Data())])
        bad.replaceSubrange(62..<66, with: [0x80, 0x81, 0x82, 0x83])
        bad.replaceSubrange(80..<84, with: [0x80, 0x81, 0x82, 0x84])
        #expect(throws: LegacyLanguageError.invalidPhysicalHeader) { try LegacyLanguageProfileReader.decodeContainer(bad) }
        #expect(throws: LegacyLanguageError.limitExceeded) { try LegacyLanguageProfileReader.decodeContainer(good, limits: .init(maximumDirectoryRecords: 0)) }
        #expect(throws: LegacyLanguageError.limitExceeded) { try LegacyLanguageProfileReader.decodeContainer(good, limits: .init(maximumProfiles: 0)) }
        #expect(throws: LegacyLanguageError.limitExceeded) { try LegacyLanguageProfileReader.decodeContainer(good, limits: .init(maximumFileBytes: good.count - 1)) }
    }

    @Test func rejectsCallbacksFrenchAndMismatchedDefinitions() throws {
        let ordinary = try LegacyLanguageProfileReader.decodeProfile(profile(version: nil))
        let table = try LegacyLanguageProfileReader.decodeCollation(collation(rows: []))
        _ = try LegacyWeightedComparisonContext(profile: ordinary, collation: table)
        let callbacks = try LegacyLanguageProfileReader.decodeProfile(profile(version: nil, callback: Data([0x80])))
        #expect(throws: LegacyLanguageError.unsupportedCallbacks) { try LegacyWeightedComparisonContext(profile: callbacks, collation: table) }
        let french = try LegacyLanguageProfileReader.decodeProfile(profile(version: nil, collationID: 0x040c))
        #expect(throws: LegacyLanguageError.unsupportedFrenchComparison) { try LegacyWeightedComparisonContext(profile: french, collation: LegacyLanguageProfileReader.decodeCollation(collation(id: 0x040c, rows: []))) }
        #expect(throws: LegacyLanguageError.collationMismatch) { try LegacyWeightedComparisonContext(profile: ordinary, collation: LegacyLanguageProfileReader.decodeCollation(collation(id: 7, rows: []))) }
    }

    @Test func strideTenKeepsDuplicateBoundaryAndUnprobedTail() throws {
        let rows: [[UInt16]] = (1...9).map { [UInt16($0), 0, UInt16($0), 0, 0] } + [[10, 11, 50, 0, 0], [10, 0, 60, 0, 0], [11, 0, 70, 0, 0]]
        let context = try context(rows)
        #expect(try context.weights([10, 11]) == [60, 82])
        #expect(try context.weights([11]) == [82])
        #expect(try context.weights([0x010b]) == [82])
    }

    @Test func preservesContractionPrimaryGroupsAndZeroOnlyWeight() throws {
        let rows: [[UInt16]] = [[1, 0, 0, 0, 0], [2, 0, 20, 0, 0], [3, 4, 30, 0, 0], [4, 0, 40, 0, 0]] +
            (5...11).map { [UInt16($0), 0, UInt16($0), 0, 0] }
        let context = try context(rows)
        #expect(try context.weights([3, 4]) == [30])
        #expect(try context.weights([1, 2, 1, 3, 4]) == [20, 30])
        #expect(try context.weights([1]) == [0])
        #expect(try context.compare([], [1]) == -1)
        #expect(try context.compare([2, 1], [2]) == 0)
        #expect(try context.weights([2, 0, 4]) == [20])
    }

    @Test func modifiersRequireBothContextWordAndEnableArgument() throws {
        let rows: [[UInt16]] = [[1, 0, 5, 7, 11]]
        let disabled = try context(rows)
        let enabled = try context(rows, word06: 1, word08: 0xffff)
        #expect(try disabled.weights([1]) == [5])
        #expect(try enabled.weights([1]) == [23])
        #expect(try enabled.weights([1], enableWord06: false) == [12])
        #expect(try enabled.weights([1], enableWord08: false) == [16])
        #expect(try enabled.weights([1], enableWord06: false, enableWord08: false) == [5])
    }

    @Test func weightAdditionWrapsUInt32AndLimitsDoNotReturnPartialOutput() throws {
        let context = try context([[1, 0, 0, 0xffff, 0xffff]], word06: 1, word08: 1)
        let units = Array(repeating: UInt16(1), count: 32769)
        #expect(try context.weights(units, limits: .init(maximumUnits: units.count)) == [UInt32(65535) &* 2 &* UInt32(units.count)])
        #expect(throws: LegacyLanguageError.limitExceeded) { try context.weights([1, 1], limits: .init(maximumUnits: 1)) }
        #expect(throws: LegacyLanguageError.limitExceeded) { try context.weights([1], limits: .init(maximumLookupSteps: 1)) }
        #expect(try context.weights([1], limits: .init(maximumLookupSteps: 2)) == [131070])
        #expect(throws: LegacyLanguageError.limitExceeded) { try context.compare([1], [1], limits: .init(maximumLookupSteps: 2)) }
        #expect(throws: LegacyLanguageError.invalidLimits) { try context.weights([], limits: .init(maximumUnits: -1)) }
    }

    @Test func compatibilityIsIndependentOfLanguageOrFullCallbackInference() {
        let left = LegacyLanguageComparisonIdentity(pageComparisonCallbackBits: 0, collationIdentifier: 1)
        #expect(left.isCompatible(with: .init(pageComparisonCallbackBits: 0, collationIdentifier: 2)))
        #expect(left.isCompatible(with: .init(pageComparisonCallbackBits: 0xffffffff, collationIdentifier: 1)))
        #expect(!left.isCompatible(with: .init(pageComparisonCallbackBits: 0x80000000, collationIdentifier: 2)))
    }

    @Test func cancelledTaskCannotProducePartialLanguageData() async throws {
        let bytes = container([("ldat", profile(version: 1))])
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try LegacyLanguageProfileReader.decodeContainer(bytes)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled reader returned data") }
        catch is CancellationError {}
    }

    private func context(_ rows: [[UInt16]], word06: UInt16 = 0, word08: UInt16 = 0) throws -> LegacyWeightedComparisonContext {
        try .init(profile: LegacyLanguageProfileReader.decodeProfile(profile(version: nil, word06: word06, word08: word08)),
                  collation: LegacyLanguageProfileReader.decodeCollation(collation(rows: rows)))
    }
    private func profile(version: UInt16?, module: Data = Data([0xfd]), callback: Data = Data(),
                         word06: UInt16 = 0, word08: UInt16 = 0, collationID: UInt16 = 0x1234) -> Data {
        var bytes = Data()
        if let version { put(version, into: &bytes) }
        put(0x1234, into: &bytes); put(0x2345, into: &bytes); put(0xabcd, into: &bytes); bytes.append(0x89)
        for value in [module, Data([0xc1]), Data([0x80, 0xfe])] { put(UInt16(value.count), into: &bytes); bytes.append(value) }
        if let version, version > 0 { put(2, into: &bytes); bytes.append(contentsOf: [0, 0xff, 0xfa]) }
        for index in 0..<7 { let value = index == 3 ? callback : Data(); put(UInt16(value.count), into: &bytes); bytes.append(value) }
        for value in [word06, word08, 0x4567, collationID, 0x6789] { put(value, into: &bytes) }
        return bytes
    }
    private func collation(id: UInt16 = 0x1234, rows: [[UInt16]]) -> Data {
        var bytes = Data(); put(id, into: &bytes); put(UInt16(rows.count), into: &bytes)
        for row in rows { for value in row { put(value, into: &bytes) } }
        return bytes
    }
    private func container(_ packets: [(String, Data)]) -> Data {
        let directorySize = 18 * (packets.count + 1)
        var directory = Data("LSFFLANG".utf8); directory.append(Data(repeating: 0, count: 10))
        var payload = Data()
        for (tag, bytes) in packets {
            let offset = 44 + directorySize + payload.count + 8
            directory.append(Data(tag.prefix(4).utf8)); directory.append(contentsOf: [0, 0, 0, 0])
            put32(UInt32(bytes.count), into: &directory); put32(UInt32(offset), into: &directory); put(0, into: &directory)
            payload.append(Data(tag.prefix(4).utf8)); put32(UInt32(bytes.count), into: &payload); payload.append(bytes)
        }
        var result = Data("LSFF".utf8); put32(UInt32(44 + directory.count + payload.count - 8), into: &result)
        result.append(Data("LANG".utf8)); result.append(Data(repeating: 0, count: 24)); result.append(Data("pcr ".utf8))
        put32(UInt32(directorySize), into: &result); result.append(directory); result.append(payload)
        return result
    }
    private func put(_ value: UInt16, into bytes: inout Data) { bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8)) }
    private func put32(_ value: UInt32, into bytes: inout Data) { put(UInt16(truncatingIfNeeded: value), into: &bytes); put(UInt16(truncatingIfNeeded: value >> 16), into: &bytes) }
}
