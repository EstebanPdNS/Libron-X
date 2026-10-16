import Foundation
#if canImport(CLibronxCompression)
import CLibronxCompression
#endif

/// These values remain in the original index domain. No source-text unit,
/// morphology, ranking, or result-node projection is inferred here.
public struct LegacyBodyPosting: Sendable, Codable, Equatable {
    public let decodedOffset: Int
    public let positionBits: UInt32
    public let extentBits: UInt8
    public let metadataBits: UInt16
}

public struct LegacyBodyPostingGroup: Sendable, Codable, Equatable {
    public let decodedOffset: Int
    public let articleBits: UInt32
    public let postings: [LegacyBodyPosting]
}

public struct LegacyBodyPostings: Sendable, Codable, Equatable {
    /// The native iterator reads this word independently of its hit countdown.
    /// In the bounded RVR60 observation it equals the number of groups.
    public let leadingMetadataWord: UInt32
    public let expectedHitCount: UInt32
    public let decodedByteCount: Int
    public let groups: [LegacyBodyPostingGroup]

    public var hitCount: Int { groups.reduce(0) { $0 + $1.postings.count } }
    public var leadingWordMatchesGroupCount: Bool {
        UInt64(leadingMetadataWord) == UInt64(groups.count)
    }
}

/// One exact dictionary row, retaining its encoded key rather than assigning
/// the original engine's collation or normalization rules to it.
public struct LegacyBodyTermPostings: Sendable, Codable, Equatable {
    public let dictionaryRow: Int
    public let dictionaryKeyBytes: Data
    public let indexInfoWord: UInt16
    public let packetFileOffset: UInt64
    public let packetByteCount: Int
    public let postings: LegacyBodyPostings
}

public struct LegacyPostingsLimits: Sendable, Equatable {
    public var maximumDictionaryRows: Int
    public var maximumPacketBytes: Int
    public var maximumDecodedBytes: Int
    public var maximumHits: Int
    public var maximumGroups: Int
    public var maximumBlocks: Int

    public init(maximumDictionaryRows: Int = 500_000,
                maximumPacketBytes: Int = 16 * 1024 * 1024,
                maximumDecodedBytes: Int = 16 * 1024 * 1024,
                maximumHits: Int = 500_000,
                maximumGroups: Int = 500_000,
                maximumBlocks: Int = 4096) {
        self.maximumDictionaryRows = maximumDictionaryRows
        self.maximumPacketBytes = maximumPacketBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumHits = maximumHits
        self.maximumGroups = maximumGroups
        self.maximumBlocks = maximumBlocks
    }

    fileprivate var valid: Bool {
        (1...1_000_000).contains(maximumDictionaryRows) &&
        (9...32 * 1024 * 1024).contains(maximumPacketBytes) &&
        (4...32 * 1024 * 1024).contains(maximumDecodedBytes) &&
        (0...1_000_000).contains(maximumHits) &&
        (0...1_000_000).contains(maximumGroups) &&
        (1...65_536).contains(maximumBlocks)
    }
}

public enum LegacyPostingsError: Error, Sendable, Equatable, LocalizedError {
    case invalidLimits
    case mismatchedPair
    case missingBodyIndex
    case invalidIndex(String)
    case dictionaryRowNotFound(Int)
    case limitExceeded
    case unsupportedStream(external: UInt16, mode: UInt16)
    case invalidPacket
    case decompressionFailed(Int32)
    case invalidGroupCount(Int16)
    case invalidNumericPayload
    case trailingData

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "The postings limits are invalid."
        case .mismatchedPair: "The LSF and LIX identifiers do not match."
        case .missingBodyIndex: "The LIX has no supported BWDX body index."
        case let .invalidIndex(tag): "The body-index table is inconsistent: \(tag)."
        case let .dictionaryRowNotFound(row): "Body-index dictionary row \(row) does not exist."
        case .limitExceeded: "The postings exceed the configured reconstruction limits."
        case let .unsupportedStream(external, mode): "Unsupported postings stream words: \(external), \(mode)."
        case .invalidPacket: "The postings packet is truncated or inconsistent."
        case let .decompressionFailed(status): "DCL postings decompression failed: \(status)."
        case let .invalidGroupCount(count): "Invalid signed postings group count: \(count)."
        case .invalidNumericPayload: "The numeric postings payload does not fit its dictionary hit count."
        case .trailingData: "Bytes remain after the complete postings payload."
        }
    }
}

public enum LegacyPostingsReader {
    /// Reads one bounded BWDX row from a checked pair. Selection by dictionary
    /// row is explicit; this does not emulate the native keyword comparator.
    public static func readBodyTerm(lsfURL: URL, lixURL: URL, dictionaryRow: Int,
                                    limits: LegacyPostingsLimits = .init()) throws -> LegacyBodyTermPostings {
        guard limits.valid else { throw LegacyPostingsError.invalidLimits }
        let index = try LegacyBodyIndex.open(lsfURL: lsfURL, lixURL: lixURL,
                                              maximumRows: limits.maximumDictionaryRows)
        let row = try index.row(at: dictionaryRow)
        guard row.keyEnd - row.keyStart <= 8192,
              row.hitEnd - row.hitStart <= UInt64(limits.maximumPacketBytes) else {
            throw LegacyPostingsError.limitExceeded
        }
        let key = try index.read(offset: index.keys.offset + row.keyStart,
                                 count: Int(row.keyEnd - row.keyStart))
        let packet = try index.read(offset: index.hits.offset + row.hitStart,
                                    count: Int(row.hitEnd - row.hitStart))
        let parsed = try decodePacket(packet, expectedHitCount: row.expectedHitCount, limits: limits)
        return LegacyBodyTermPostings(dictionaryRow: dictionaryRow, dictionaryKeyBytes: key,
            indexInfoWord: index.indexInfoWord, packetFileOffset: index.hits.offset + row.hitStart,
            packetByteCount: packet.count, postings: parsed)
    }

    /// The observed external word 0 / compressed-file mode 1 family. Zero block
    /// flag means raw; every nonzero flag selects DCL, as in the native branch.
    /// Bounds, positive group counts and exact tails are reconstruction guards,
    /// not a claim about the original's malformed-input acceptance.
    public static func decodePacket(_ packet: Data, expectedHitCount: UInt32,
                                     limits: LegacyPostingsLimits = .init()) throws -> LegacyBodyPostings {
        guard limits.valid else { throw LegacyPostingsError.invalidLimits }
        guard packet.count <= limits.maximumPacketBytes,
              UInt64(expectedHitCount) <= UInt64(limits.maximumHits) else {
            throw LegacyPostingsError.limitExceeded
        }
        let bytes = [UInt8](packet)
        guard bytes.count >= 9 else { throw LegacyPostingsError.invalidPacket }
        let external = u16(bytes, 0), mode = u16(bytes, 2), sizingHint = Int(u16(bytes, 4))
        guard external == 0, mode == 1 else {
            throw LegacyPostingsError.unsupportedStream(external: external, mode: mode)
        }
        guard sizingHint > 0 else { throw LegacyPostingsError.invalidPacket }
        var at = 6, blocks = 0, decoded = Data()
        while at < bytes.count {
            try Task.checkCancellation()
            guard blocks < limits.maximumBlocks else { throw LegacyPostingsError.limitExceeded }
            guard 3 <= bytes.count - at else { throw LegacyPostingsError.invalidPacket }
            let compressed = bytes[at] != 0, lengthAndLast = u16(bytes, at + 1)
            let length = Int(lengthAndLast & 0x7fff), last = lengthAndLast & 0x8000 != 0
            at += 3
            guard length > 0, length <= bytes.count - at else { throw LegacyPostingsError.invalidPacket }
            let remainingBudget = limits.maximumDecodedBytes - decoded.count
            let stored = Data(bytes[at..<(at + length)])
            let block: Data
            if compressed {
                block = try decompress(stored, initialCapacity: sizingHint, maximumCapacity: remainingBudget)
            } else {
                guard length <= remainingBudget else { throw LegacyPostingsError.limitExceeded }
                block = stored
            }
            decoded.append(block)
            at += length
            blocks += 1
            if last {
                guard at == bytes.count else { throw LegacyPostingsError.trailingData }
                return try decodeNumericPayload(decoded, expectedHitCount: expectedHitCount, limits: limits)
            }
        }
        throw LegacyPostingsError.invalidPacket
    }

    /// The dictionary hit total drives iteration. The leading payload word is
    /// retained without requiring it to equal the independently observed groups.
    public static func decodeNumericPayload(_ payload: Data, expectedHitCount: UInt32,
                                             limits: LegacyPostingsLimits = .init()) throws -> LegacyBodyPostings {
        guard limits.valid else { throw LegacyPostingsError.invalidLimits }
        guard payload.count <= limits.maximumDecodedBytes,
              UInt64(expectedHitCount) <= UInt64(limits.maximumHits) else {
            throw LegacyPostingsError.limitExceeded
        }
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else { throw LegacyPostingsError.invalidNumericPayload }
        let metadata = u32(bytes, 0)
        var at = 4, count = 0, groups: [LegacyBodyPostingGroup] = []
        while count < Int(expectedHitCount) {
            try Task.checkCancellation()
            guard groups.count < limits.maximumGroups else { throw LegacyPostingsError.limitExceeded }
            guard 6 <= bytes.count - at else { throw LegacyPostingsError.invalidNumericPayload }
            let groupOffset = at, article = u32(bytes, at)
            let groupCount = Int16(bitPattern: u16(bytes, at + 4))
            at += 6
            guard groupCount > 0 else { throw LegacyPostingsError.invalidGroupCount(groupCount) }
            let amount = Int(groupCount)
            guard amount <= Int(expectedHitCount) - count,
                  amount <= (bytes.count - at) / 7 else {
                throw LegacyPostingsError.invalidNumericPayload
            }
            var postings: [LegacyBodyPosting] = []
            postings.reserveCapacity(amount)
            for _ in 0..<amount {
                postings.append(LegacyBodyPosting(decodedOffset: at, positionBits: u32(bytes, at),
                    extentBits: bytes[at + 4], metadataBits: u16(bytes, at + 5)))
                at += 7
            }
            groups.append(LegacyBodyPostingGroup(decodedOffset: groupOffset, articleBits: article, postings: postings))
            count += amount
        }
        guard at == bytes.count else { throw LegacyPostingsError.trailingData }
        return LegacyBodyPostings(leadingMetadataWord: metadata, expectedHitCount: expectedHitCount,
                                  decodedByteCount: bytes.count, groups: groups)
    }

    private static func decompress(_ input: Data, initialCapacity: Int, maximumCapacity: Int) throws -> Data {
        guard maximumCapacity > 0 else { throw LegacyPostingsError.limitExceeded }
        #if canImport(CLibronxCompression)
        var capacity = min(initialCapacity, maximumCapacity)
        while true {
            try Task.checkCancellation()
            var output = Data(count: capacity), written = 0
            let status = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    libronx_explode_exact(source.bindMemory(to: UInt8.self).baseAddress, source.count,
                        destination.bindMemory(to: UInt8.self).baseAddress, destination.count, &written)
                }
            }
            if status == 1 {
                guard capacity < maximumCapacity else { throw LegacyPostingsError.limitExceeded }
                capacity = min(capacity * 2, maximumCapacity)
                continue
            }
            guard status == 0 else { throw LegacyPostingsError.decompressionFailed(Int32(status)) }
            guard written <= capacity else { throw LegacyPostingsError.invalidPacket }
            output.count = written
            return output
        }
        #else
        throw LegacyPostingsError.decompressionFailed(-101)
        #endif
    }


    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 |
        UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
