import Foundation

/// Unsigned units are authoritative. String decoding would replace unpaired
/// surrogates and cannot represent every original dictionary key exactly.
public struct LegacyDictionaryKey: Sendable, Codable, Equatable {
    public let selector: UInt8
    public let units: [UInt16]
    public let consumedByteCount: Int
    public let storedByteCount: Int
}

public struct LegacyDictionaryMatch: Sendable, Codable, Equatable {
    public let dictionaryRow: Int
    public let key: LegacyDictionaryKey
    public let expectedHitCount: UInt32
    public let packetFileOffset: UInt64
    public let packetByteCount: Int
}

public struct LegacyLiteralDictionaryLookup: Sendable, Codable, Equatable {
    public let requestedUnits: [UInt16]
    public let scannedRows: Int
    public let scannedKeyBytes: Int
    public let decodedUnitCount: Int
    public let indexInfoWord: UInt16
    /// Duplicates remain distinct in original dictionary row order.
    public let matches: [LegacyDictionaryMatch]
}

public struct LegacyDictionaryLimits: Sendable, Equatable {
    public var maximumRows: Int
    public var maximumKeyTableBytes: Int
    public var maximumStoredKeyBytes: Int
    public var maximumKeyUnits: Int
    public var maximumTotalUnits: Int
    public var maximumMatches: Int

    public init(maximumRows: Int = 500_000,
                maximumKeyTableBytes: Int = 32 * 1024 * 1024,
                maximumStoredKeyBytes: Int = 8192,
                maximumKeyUnits: Int = 4096,
                maximumTotalUnits: Int = 8 * 1024 * 1024,
                maximumMatches: Int = 64) {
        self.maximumRows = maximumRows; self.maximumKeyTableBytes = maximumKeyTableBytes
        self.maximumStoredKeyBytes = maximumStoredKeyBytes; self.maximumKeyUnits = maximumKeyUnits
        self.maximumTotalUnits = maximumTotalUnits; self.maximumMatches = maximumMatches
    }

    fileprivate var valid: Bool {
        (0...1_000_000).contains(maximumRows) &&
        (0...64 * 1024 * 1024).contains(maximumKeyTableBytes) &&
        (2...65_536).contains(maximumStoredKeyBytes) &&
        (0...32_768).contains(maximumKeyUnits) &&
        (0...16 * 1024 * 1024).contains(maximumTotalUnits) &&
        (0...65_536).contains(maximumMatches)
    }
}

public enum LegacyDictionaryError: Error, Sendable, Equatable, LocalizedError {
    case invalidLimits
    case limitExceeded
    case missingTerminator
    case invalidLiteral

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "The dictionary limits are invalid."
        case .limitExceeded: "The dictionary exceeds the configured reconstruction limits."
        case .missingTerminator: "The dictionary key has no complete terminator within its row."
        case .invalidLiteral: "A literal dictionary key cannot contain a zero unit."
        }
    }
}

public enum LegacyDictionaryReader {
    /// 0xf0 selects little-endian unsigned 16-bit units terminated by u16 zero.
    /// Every other selector supplies the high byte of zero-terminated low bytes.
    /// Consumption ends at the terminator; row padding is deliberately retained
    /// in storedByteCount and does not become key data.
    public static func decodeKey(_ bytes: Data, limits: LegacyDictionaryLimits = .init()) throws -> LegacyDictionaryKey {
        guard limits.valid else { throw LegacyDictionaryError.invalidLimits }
        guard bytes.count <= limits.maximumStoredKeyBytes else { throw LegacyDictionaryError.limitExceeded }
        guard let selector = bytes.first else { throw LegacyDictionaryError.missingTerminator }
        var at = 1, units: [UInt16] = []
        while at < bytes.count {
            let unit: UInt16
            if selector == 0xf0 {
                guard bytes.count - at >= 2 else { throw LegacyDictionaryError.missingTerminator }
                unit = LegacyBodyIndex.u16(bytes, at)
                at += 2
            } else {
                let low = bytes[bytes.startIndex + at]
                at += 1
                if low == 0 {
                    return LegacyDictionaryKey(selector: selector, units: units,
                        consumedByteCount: at, storedByteCount: bytes.count)
                }
                unit = UInt16(selector) << 8 | UInt16(low)
            }
            if unit == 0 {
                return LegacyDictionaryKey(selector: selector, units: units,
                    consumedByteCount: at, storedByteCount: bytes.count)
            }
            guard units.count < limits.maximumKeyUnits else { throw LegacyDictionaryError.limitExceeded }
            units.append(unit)
        }
        throw LegacyDictionaryError.missingTerminator
    }

    /// Exact raw-unit selection, with no normalization, stoplist or language
    /// collation. The native dictionary is not assumed ordinally sorted.
    /// All rows are checked before returning, including rows after a match.
    public static func lookupExact(lsfURL: URL, lixURL: URL, units: [UInt16],
                                   limits: LegacyDictionaryLimits = .init()) throws -> LegacyLiteralDictionaryLookup {
        guard limits.valid else { throw LegacyDictionaryError.invalidLimits }
        guard units.count <= limits.maximumKeyUnits else { throw LegacyDictionaryError.limitExceeded }
        guard !units.contains(0) else { throw LegacyDictionaryError.invalidLiteral }
        try Task.checkCancellation()
        let index = try LegacyBodyIndex.open(lsfURL: lsfURL, lixURL: lixURL, maximumRows: limits.maximumRows)
        guard index.keys.length <= UInt64(limits.maximumKeyTableBytes) else {
            throw LegacyDictionaryError.limitExceeded
        }
        let headers = try index.read(offset: index.headers.offset, count: Int(index.headers.length))
        let keys = try index.read(offset: index.keys.offset, count: Int(index.keys.length))
        var totalUnits = 0, matches: [LegacyDictionaryMatch] = []
        for ordinal in 0..<index.rowCount {
            try Task.checkCancellation()
            let row = try index.row(at: ordinal, headerBytes: headers, byteOffset: ordinal * 12)
            guard row.keyEnd - row.keyStart <= UInt64(limits.maximumStoredKeyBytes) else {
                throw LegacyDictionaryError.limitExceeded
            }
            let key = try decodeKey(keys.subdata(in: Int(row.keyStart)..<Int(row.keyEnd)), limits: limits)
            guard key.units.count <= limits.maximumTotalUnits - totalUnits else {
                throw LegacyDictionaryError.limitExceeded
            }
            totalUnits += key.units.count
            if key.units == units {
                guard matches.count < limits.maximumMatches else { throw LegacyDictionaryError.limitExceeded }
                // File offsets are bounded by the checked chunk and original file.
                matches.append(LegacyDictionaryMatch(dictionaryRow: ordinal, key: key,
                    expectedHitCount: row.expectedHitCount,
                    packetFileOffset: index.hits.offset + row.hitStart,
                    packetByteCount: Int(row.hitEnd - row.hitStart)))
            }
        }
        return LegacyLiteralDictionaryLookup(requestedUnits: units, scannedRows: index.rowCount,
            scannedKeyBytes: keys.count, decodedUnitCount: totalUnits,
            indexInfoWord: index.indexInfoWord, matches: matches)
    }
}
