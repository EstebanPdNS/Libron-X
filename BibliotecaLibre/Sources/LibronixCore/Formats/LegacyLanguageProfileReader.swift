import Foundation

/// Serialized definitions only. Reading a record does not resolve a native DLL or live context.
public struct LegacyLanguageProfile: Sendable, Codable, Equatable {
    /// Nil means the first word was an unversioned language identifier (>100).
    public let serializedVersion: UInt16?
    public let languageIdentifier: UInt16
    public let unitMapIdentifier: UInt16
    public let word2A: UInt16
    public let byte2C: UInt8
    public let moduleNameBytes: Data
    public let label1CBytes: Data
    public let label20Bytes: Data
    public let extra24Bytes: Data?
    public let byte28: UInt8?
    /// Native serialized order: +48, +4c, +44, +58, +50, +54, +5c.
    public let callbackNameBytes: [Data]
    public let modifierWord06: UInt16
    public let modifierWord08: UInt16
    public let word0A: UInt16
    public let collationIdentifier: UInt16
    public let phoneticIdentifier: UInt16
    public let rawPacket: Data
}

public struct LegacyCollationRow: Sendable, Codable, Equatable {
    public let firstUnit: UInt16
    public let secondUnit: UInt16
    public let primaryWeight: UInt16
    public let modifier06: UInt16
    public let modifier08: UInt16
}

public struct LegacyCollationTable: Sendable, Codable, Equatable {
    public let identifier: UInt16
    /// Duplicate first units and contraction rows retain their serialized order.
    public let rows: [LegacyCollationRow]
    public let maximumPrimaryWeight: UInt16
    public let rawPacket: Data
}

public struct LegacyLanguageData: Sendable, Equatable {
    public let profiles: [LegacyLanguageProfile]
    public let collations: [LegacyCollationTable]
    public let directoryRecordCount: Int

    /// Unique explicit definition selection is a reconstruction policy, not live native resolution.
    public func profile(languageIdentifier: UInt16) throws -> LegacyLanguageProfile {
        let matching = profiles.filter { $0.languageIdentifier == languageIdentifier }
        guard matching.count == 1 else {
            throw LegacyLanguageError.profileSelection(languageIdentifier, matches: matching.count)
        }
        return matching[0]
    }

    public func collation(identifier: UInt16) throws -> LegacyCollationTable {
        let matching = collations.filter { $0.identifier == identifier }
        guard matching.count == 1 else {
            throw LegacyLanguageError.collationSelection(identifier, matches: matching.count)
        }
        return matching[0]
    }

    public func weightedContext(languageIdentifier: UInt16) throws -> LegacyWeightedComparisonContext {
        let definition = try profile(languageIdentifier: languageIdentifier)
        return try .init(profile: definition, collation: collation(identifier: definition.collationIdentifier))
    }
}

public struct LegacyLanguageReadLimits: Sendable, Equatable {
    public var maximumFileBytes: Int
    public var maximumDirectoryRecords: Int
    public var maximumProfiles: Int
    public var maximumCollations: Int
    public var maximumPacketBytes: Int
    public var maximumStringBytes: Int
    public var maximumCollationRows: Int

    public init(maximumFileBytes: Int = 16 * 1024 * 1024, maximumDirectoryRecords: Int = 4096,
                maximumProfiles: Int = 512, maximumCollations: Int = 128,
                maximumPacketBytes: Int = 256 * 1024, maximumStringBytes: Int = 4096,
                maximumCollationRows: Int = 8192) {
        self.maximumFileBytes = maximumFileBytes; self.maximumDirectoryRecords = maximumDirectoryRecords
        self.maximumProfiles = maximumProfiles; self.maximumCollations = maximumCollations
        self.maximumPacketBytes = maximumPacketBytes; self.maximumStringBytes = maximumStringBytes
        self.maximumCollationRows = maximumCollationRows
    }

    fileprivate var valid: Bool {
        (0...32 * 1024 * 1024).contains(maximumFileBytes) &&
        (0...65_536).contains(maximumDirectoryRecords) && (0...4096).contains(maximumProfiles) &&
        (0...4096).contains(maximumCollations) && (0...1024 * 1024).contains(maximumPacketBytes) &&
        (0...32767).contains(maximumStringBytes) && (0...65_535).contains(maximumCollationRows)
    }
}

public struct LegacyWeightedComparisonLimits: Sendable, Equatable {
    public var maximumUnits: Int
    public var maximumLookupSteps: Int
    public init(maximumUnits: Int = 4096, maximumLookupSteps: Int = 8 * 1024 * 1024) {
        self.maximumUnits = maximumUnits; self.maximumLookupSteps = maximumLookupSteps
    }
    fileprivate var valid: Bool {
        (0...1024 * 1024).contains(maximumUnits) && (0...64 * 1024 * 1024).contains(maximumLookupSteps)
    }
}

public enum LegacyLanguageError: Error, Sendable, Equatable, LocalizedError {
    case invalidLimits
    case limitExceeded
    case invalidContainer
    case invalidDirectory
    case invalidPhysicalHeader
    case truncatedPacket
    case negativeStringLength
    case packetTail
    case unorderedCollation
    case profileSelection(UInt16, matches: Int)
    case collationSelection(UInt16, matches: Int)
    case collationMismatch
    case unsupportedCallbacks
    case unsupportedFrenchComparison

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "The language-data limits are invalid."
        case .limitExceeded: "The language data or comparison exceeds configured limits."
        case .invalidContainer: "The language container header is invalid."
        case .invalidDirectory: "The language container directory is invalid."
        case .invalidPhysicalHeader: "A language packet header contradicts its directory entry."
        case .truncatedPacket: "A language packet is truncated."
        case .negativeStringLength: "A language byte-string length is negative."
        case .packetTail: "A language packet has unconsumed bytes."
        case .unorderedCollation: "The collation first-unit rows are not ordered."
        case let .profileSelection(code, count): "Language definition \(code) has \(count) matching records."
        case let .collationSelection(code, count): "Collation definition \(code) has \(count) matching records."
        case .collationMismatch: "The selected collation does not match the language definition."
        case .unsupportedCallbacks: "Serialized language callbacks are unsupported by this portable comparator."
        case .unsupportedFrenchComparison: "The French expansion comparison branch is unsupported."
        }
    }
}

public enum LegacyLanguageProfileReader {
    public static func read(url: URL, limits: LegacyLanguageReadLimits = .init()) throws -> LegacyLanguageData {
        guard limits.valid else { throw LegacyLanguageError.invalidLimits }
        try Task.checkCancellation()
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        let size = try stream.seekToEnd()
        guard size <= UInt64(limits.maximumFileBytes) else { throw LegacyLanguageError.limitExceeded }
        try stream.seek(toOffset: 0)
        var bytes = Data()
        bytes.reserveCapacity(Int(size))
        while bytes.count < Int(size) {
            try Task.checkCancellation()
            guard let part = try stream.read(upToCount: min(64 * 1024, Int(size) - bytes.count)), !part.isEmpty else {
                throw LegacyLanguageError.truncatedPacket
            }
            bytes.append(part)
        }
        return try decodeContainer(bytes, limits: limits)
    }

    public static func decodeContainer(_ packet: Data, limits: LegacyLanguageReadLimits = .init()) throws -> LegacyLanguageData {
        guard limits.valid else { throw LegacyLanguageError.invalidLimits }
        guard packet.count <= limits.maximumFileBytes else { throw LegacyLanguageError.limitExceeded }
        try Task.checkCancellation()
        let bytes = Array(packet)
        guard bytes.count >= 62, tag(bytes, 0) == "LSFF", tag(bytes, 8) == "LANG",
              UInt64(u32(bytes, 4)) + 8 == UInt64(bytes.count), tag(bytes, 36) == "pcr " else {
            throw LegacyLanguageError.invalidContainer
        }
        let directoryBytes = Int(u32(bytes, 40))
        guard directoryBytes >= 18, directoryBytes % 18 == 0, directoryBytes <= bytes.count - 44,
              tag(bytes, 44) == "LSFF", tag(bytes, 48) == "LANG" else { throw LegacyLanguageError.invalidDirectory }
        let records = directoryBytes / 18 - 1
        guard records <= limits.maximumDirectoryRecords else { throw LegacyLanguageError.limitExceeded }
        var profiles: [LegacyLanguageProfile] = [], tables: [LegacyCollationTable] = []
        for row in 0..<records {
            try Task.checkCancellation()
            let at = 62 + row * 18, name = tag(bytes, at)
            let count = Int(u32(bytes, at + 8)), offset = Int(u32(bytes, at + 12))
            guard offset >= 8, offset <= bytes.count, count <= bytes.count - offset else { throw LegacyLanguageError.invalidDirectory }
            guard bytes[(offset - 8)..<(offset - 4)].elementsEqual(bytes[at..<(at + 4)]), Int(u32(bytes, offset - 4)) == count else {
                throw LegacyLanguageError.invalidPhysicalHeader
            }
            switch name {
            case "ldat":
                guard profiles.count < limits.maximumProfiles, count <= limits.maximumPacketBytes else { throw LegacyLanguageError.limitExceeded }
                profiles.append(try decodeProfile(Data(bytes[offset..<(offset + count)]), limits: limits))
            case "coll":
                guard tables.count < limits.maximumCollations, count <= limits.maximumPacketBytes else { throw LegacyLanguageError.limitExceeded }
                tables.append(try decodeCollation(Data(bytes[offset..<(offset + count)]), limits: limits))
            default: break
            }
        }
        return .init(profiles: profiles, collations: tables, directoryRecordCount: records)
    }

    public static func decodeProfile(_ packet: Data, limits: LegacyLanguageReadLimits = .init()) throws -> LegacyLanguageProfile {
        guard limits.valid else { throw LegacyLanguageError.invalidLimits }
        guard packet.count <= limits.maximumPacketBytes else { throw LegacyLanguageError.limitExceeded }
        try Task.checkCancellation()
        var cursor = Cursor(bytes: Array(packet), maximumStringBytes: limits.maximumStringBytes)
        let first = try cursor.word(), version: UInt16? = first > 100 ? nil : first
        let language = try version == nil ? first : cursor.word()
        let unitMap = try cursor.word(), word2A = try cursor.word(), byte2C = try cursor.byte()
        let module = try cursor.string(), label1C = try cursor.string(), label20 = try cursor.string()
        let extra: Data?, byte28: UInt8?
        if let version, version > 0 { extra = try cursor.string(); byte28 = try cursor.byte() }
        else { extra = nil; byte28 = nil }
        var callbacks: [Data] = []
        for _ in 0..<7 { callbacks.append(try cursor.string()) }
        let word06 = try cursor.word(), word08 = try cursor.word(), word0A = try cursor.word()
        let collation = try cursor.word(), phonetic = try cursor.word()
        guard cursor.at == cursor.bytes.count else { throw LegacyLanguageError.packetTail }
        return .init(serializedVersion: version, languageIdentifier: language, unitMapIdentifier: unitMap,
            word2A: word2A, byte2C: byte2C, moduleNameBytes: module, label1CBytes: label1C,
            label20Bytes: label20, extra24Bytes: extra, byte28: byte28, callbackNameBytes: callbacks,
            modifierWord06: word06, modifierWord08: word08, word0A: word0A,
            collationIdentifier: collation, phoneticIdentifier: phonetic, rawPacket: Data(cursor.bytes))
    }

    public static func decodeCollation(_ packet: Data, limits: LegacyLanguageReadLimits = .init()) throws -> LegacyCollationTable {
        guard limits.valid else { throw LegacyLanguageError.invalidLimits }
        guard packet.count <= limits.maximumPacketBytes else { throw LegacyLanguageError.limitExceeded }
        try Task.checkCancellation()
        let bytes = Array(packet)
        guard bytes.count >= 4 else { throw LegacyLanguageError.truncatedPacket }
        let count = Int(u16(bytes, 2))
        guard count <= limits.maximumCollationRows else { throw LegacyLanguageError.limitExceeded }
        guard bytes.count >= 4 + count * 10 else { throw LegacyLanguageError.truncatedPacket }
        guard bytes.count == 4 + count * 10 else { throw LegacyLanguageError.packetTail }
        var rows: [LegacyCollationRow] = []
        rows.reserveCapacity(count)
        var maximum: UInt16 = 0
        for row in 0..<count {
            if row % 256 == 0 { try Task.checkCancellation() }
            let at = 4 + row * 10
            let entry = LegacyCollationRow(firstUnit: u16(bytes, at), secondUnit: u16(bytes, at + 2),
                primaryWeight: u16(bytes, at + 4), modifier06: u16(bytes, at + 6), modifier08: u16(bytes, at + 8))
            if let previous = rows.last, previous.firstUnit > entry.firstUnit { throw LegacyLanguageError.unorderedCollation }
            rows.append(entry); maximum = max(maximum, entry.primaryWeight)
        }
        return .init(identifier: u16(bytes, 0), rows: rows, maximumPrimaryWeight: maximum, rawPacket: Data(bytes))
    }

    private struct Cursor {
        let bytes: [UInt8]
        let maximumStringBytes: Int
        var at = 0
        mutating func byte() throws -> UInt8 {
            guard at < bytes.count else { throw LegacyLanguageError.truncatedPacket }
            defer { at += 1 }; return bytes[at]
        }
        mutating func word() throws -> UInt16 {
            guard bytes.count - at >= 2 else { throw LegacyLanguageError.truncatedPacket }
            defer { at += 2 }; return LegacyLanguageProfileReader.u16(bytes, at)
        }
        mutating func string() throws -> Data {
            let signed = Int16(bitPattern: try word())
            guard signed >= 0 else { throw LegacyLanguageError.negativeStringLength }
            let count = Int(signed)
            guard count <= maximumStringBytes else { throw LegacyLanguageError.limitExceeded }
            guard count <= bytes.count - at else { throw LegacyLanguageError.truncatedPacket }
            defer { at += count }; return Data(bytes[at..<(at + count)])
        }
    }
    private static func tag(_ bytes: [UInt8], _ at: Int) -> String { String(decoding: bytes[at..<(at + 4)], as: UTF8.self) }
    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { UInt32(u16(bytes, at)) | UInt32(u16(bytes, at + 2)) << 16 }
}

public struct LegacyWeightedComparisonContext: Sendable {
    public let profile: LegacyLanguageProfile
    public let collation: LegacyCollationTable

    public init(profile: LegacyLanguageProfile, collation: LegacyCollationTable) throws {
        guard profile.collationIdentifier == collation.identifier else { throw LegacyLanguageError.collationMismatch }
        guard profile.callbackNameBytes.allSatisfy({ $0.isEmpty }) else { throw LegacyLanguageError.unsupportedCallbacks }
        guard collation.identifier != 0x040c else { throw LegacyLanguageError.unsupportedFrenchComparison }
        self.profile = profile; self.collation = collation
    }

    public func weights(_ units: [UInt16], enableWord06: Bool = true, enableWord08: Bool = true,
                        limits: LegacyWeightedComparisonLimits = .init()) throws -> [UInt32] {
        var work = 0
        return try weightValues(units, enableWord06: enableWord06, enableWord08: enableWord08, limits: limits, work: &work)
    }

    private func weightValues(_ units: [UInt16], enableWord06: Bool, enableWord08: Bool,
                              limits: LegacyWeightedComparisonLimits, work: inout Int) throws -> [UInt32] {
        guard limits.valid else { throw LegacyLanguageError.invalidLimits }
        guard units.count <= limits.maximumUnits else { throw LegacyLanguageError.limitExceeded }
        try Task.checkCancellation()
        var at = 0
        var result: [UInt32] = []
        while at < units.count, units[at] != 0 {
            var total: UInt32 = 0, sawPrimary = false
            while at < units.count, units[at] != 0 {
                try consume(&work, maximum: limits.maximumLookupSteps)
                if let row = try lookup(units, at: at, work: &work, maximum: limits.maximumLookupSteps) {
                    if sawPrimary, row.primaryWeight != 0 { break }
                    total = total &+ UInt32(row.primaryWeight)
                    if profile.modifierWord06 != 0, enableWord06 { total = total &+ UInt32(row.modifier08) }
                    if profile.modifierWord08 != 0, enableWord08 { total = total &+ UInt32(row.modifier06) }
                    at += row.secondUnit == 0 ? 1 : 2
                    sawPrimary = sawPrimary || row.primaryWeight != 0
                } else {
                    if sawPrimary { break }
                    total = total &+ UInt32(collation.maximumPrimaryWeight) &+ UInt32(units[at] & 0xff) &+ 1
                    sawPrimary = true; at += 1
                }
            }
            result.append(total)
        }
        return result
    }

    /// A supported weighted branch only, not query normalization or engine-level context resolution.
    public func compare(_ left: [UInt16], _ right: [UInt16], enableWord06: Bool = true,
                        enableWord08: Bool = true, limits: LegacyWeightedComparisonLimits = .init()) throws -> Int {
        var work = 0
        let first = try weightValues(left, enableWord06: enableWord06, enableWord08: enableWord08, limits: limits, work: &work)
        let second = try weightValues(right, enableWord06: enableWord06, enableWord08: enableWord08, limits: limits, work: &work)
        if first == second { return 0 }
        return first.lexicographicallyPrecedes(second) ? -1 : 1
    }

    private func lookup(_ units: [UInt16], at: Int, work: inout Int, maximum: Int) throws -> LegacyCollationRow? {
        let wanted = units[at], following = at + 1 < units.count ? units[at + 1] : 0
        var index = 0, step = 10
        while index < collation.rows.count {
            try consume(&work, maximum: maximum)
            let entry = collation.rows[index]
            if wanted < entry.firstUnit {
                if index == 0 || step == 1 { return nil }
                index -= step; step = 1
            }
            if wanted == entry.firstUnit, entry.secondUnit == 0 || entry.secondUnit == following { return entry }
            index += step
        }
        return nil
    }

    private func consume(_ work: inout Int, maximum: Int) throws {
        guard work < maximum else { throw LegacyLanguageError.limitExceeded }
        work += 1
        if work % 256 == 0 { try Task.checkCancellation() }
    }
}

/// Raw caller-supplied identity fields for the separate compatibility predicate.
/// It never derives callback pointer identity from a serialized module/name or LCID.
public struct LegacyLanguageComparisonIdentity: Sendable, Equatable {
    public let pageComparisonCallbackBits: UInt32
    public let collationIdentifier: UInt16
    public init(pageComparisonCallbackBits: UInt32, collationIdentifier: UInt16) {
        self.pageComparisonCallbackBits = pageComparisonCallbackBits
        self.collationIdentifier = collationIdentifier
    }
    public func isCompatible(with other: Self) -> Bool {
        pageComparisonCallbackBits == other.pageComparisonCallbackBits || collationIdentifier == other.collationIdentifier
    }
}
