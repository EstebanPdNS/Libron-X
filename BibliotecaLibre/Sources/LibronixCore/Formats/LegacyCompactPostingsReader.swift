import Foundation
#if canImport(CLibronxCompression)
import CLibronxCompression
#endif

/// The compact wire branch has no per-hit opaque UInt16 field.
public struct LegacyCompactPosting: Sendable, Codable, Equatable {
    public let decodedOffset: Int
    public let positionBits: UInt32
    public let extentBits: UInt8
}

public struct LegacyCompactPostingGroup: Sendable, Codable, Equatable {
    public let decodedOffset: Int
    public let articleBits: UInt32
    public let postings: [LegacyCompactPosting]
}

public struct LegacyCompactPostings: Sendable, Codable, Equatable {
    public let leadingMetadataWord: UInt32
    public let expectedHitCount: UInt32
    public let decodedByteCount: Int
    public let groups: [LegacyCompactPostingGroup]
    public var hitCount: Int { groups.reduce(0) { $0 + $1.postings.count } }
}

public struct LegacyCompactTermPostings: Sendable, Codable, Equatable {
    /// Source-directory order among WIDX parent entries; never chosen implicitly.
    public let indexOrdinal: Int
    public let parentFileOffset: UInt64
    public let dictionaryRow: Int
    public let dictionaryKeyBytes: Data
    public let indexInfoWord: UInt16
    public let packetFileOffset: UInt64
    public let packetByteCount: Int
    public let postings: LegacyCompactPostings
}

public struct LegacyCompactPostingsLimits: Sendable, Equatable {
    public var maximumIndices: Int
    public var maximumDictionaryRows: Int
    public var maximumKeyBytes: Int
    public var maximumPacketBytes: Int
    public var maximumDecodedBytes: Int
    public var maximumHits: Int
    public var maximumGroups: Int
    public var maximumBlocks: Int

    public init(maximumIndices: Int = 64, maximumDictionaryRows: Int = 500_000,
                maximumKeyBytes: Int = 8192, maximumPacketBytes: Int = 16 * 1024 * 1024,
                maximumDecodedBytes: Int = 16 * 1024 * 1024, maximumHits: Int = 500_000,
                maximumGroups: Int = 500_000, maximumBlocks: Int = 4096) {
        self.maximumIndices = maximumIndices; self.maximumDictionaryRows = maximumDictionaryRows
        self.maximumKeyBytes = maximumKeyBytes; self.maximumPacketBytes = maximumPacketBytes
        self.maximumDecodedBytes = maximumDecodedBytes; self.maximumHits = maximumHits
        self.maximumGroups = maximumGroups; self.maximumBlocks = maximumBlocks
    }
    fileprivate var valid: Bool {
        (1...4096).contains(maximumIndices) && (0...1_000_000).contains(maximumDictionaryRows) &&
        (0...65_536).contains(maximumKeyBytes) && (9...32 * 1024 * 1024).contains(maximumPacketBytes) &&
        (4...32 * 1024 * 1024).contains(maximumDecodedBytes) && (0...1_000_000).contains(maximumHits) &&
        (0...1_000_000).contains(maximumGroups) && (1...65_536).contains(maximumBlocks)
    }
}

public enum LegacyCompactPostingsError: Error, Sendable, Equatable, LocalizedError {
    case invalidLimits
    case pairIdentifiersUnavailable
    case mismatchedPair
    case indexOrdinalNotFound(Int, available: Int)
    case dictionaryRowNotFound(Int)
    case invalidIndex(String)
    case limitExceeded
    case unsupportedStream(external: UInt16, mode: UInt16)
    case invalidPacket
    case invalidGroupCount(Int16)
    case invalidNumericPayload
    case trailingData
    case decompressionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "The compact postings limits are invalid."
        case .pairIdentifiersUnavailable: "The resource pair identifiers cannot be compared."
        case .mismatchedPair: "The resource pair identifiers differ."
        case let .indexOrdinalNotFound(ordinal, available): "Compact index ordinal \(ordinal) does not exist among \(available) parents."
        case let .dictionaryRowNotFound(row): "Compact dictionary row \(row) does not exist."
        case let .invalidIndex(tag): "The compact index framing is inconsistent: \(tag)."
        case .limitExceeded: "The compact postings exceed configured reconstruction limits."
        case let .unsupportedStream(external, mode): "Unsupported compact stream words: \(external), \(mode)."
        case .invalidPacket: "The compact packet is truncated or inconsistent."
        case let .invalidGroupCount(count): "Invalid signed compact group count: \(count)."
        case .invalidNumericPayload: "The compact payload contradicts its external hit count."
        case .trailingData: "Bytes remain after the compact stream."
        case let .decompressionFailed(status): "Compact DCL decompression failed: \(status)."
        }
    }
}

public enum LegacyCompactPostingsReader {
    /// Explicit ordinal/row only. No dictionary comparator, native index selection,
    /// normalization, coordinate conversion, RTAX projection or engine evaluation.
    public static func readTerm(lsfURL: URL, lixURL: URL, indexOrdinal: Int, dictionaryRow: Int,
                                limits: LegacyCompactPostingsLimits = .init()) throws -> LegacyCompactTermPostings {
        guard limits.valid else { throw LegacyCompactPostingsError.invalidLimits }
        try Task.checkCancellation()
        let pair = try LegacyResourceReader.inspect(lsfURL: lsfURL, lixURL: lixURL)
        guard let matched = pair.identifiersMatch, let metadata = pair.lix else {
            throw LegacyCompactPostingsError.pairIdentifiersUnavailable
        }
        guard matched else { throw LegacyCompactPostingsError.mismatchedPair }
        let parents = metadata.blocks.filter { $0.tag == "WIDX" }
        guard parents.count <= limits.maximumIndices else { throw LegacyCompactPostingsError.limitExceeded }
        guard indexOrdinal >= 0, indexOrdinal < parents.count else {
            throw LegacyCompactPostingsError.indexOrdinalNotFound(indexOrdinal, available: parents.count)
        }
        let parent = parents[indexOrdinal]
        func child(_ tag: String) throws -> LegacyBlock {
            let matches = metadata.blocks.filter {
                $0.tag == tag && $0.offset >= parent.offset && $0.length <= parent.length &&
                $0.offset - parent.offset <= parent.length - $0.length
            }
            guard matches.count == 1 else { throw LegacyCompactPostingsError.invalidIndex("WIDX/" + tag) }
            return matches[0]
        }
        let info = try child("info"), headers = try child("hlst"), keys = try child("klst"), hits = try child("hits")
        let stream = try FileHandle(forReadingFrom: lixURL)
        defer { try? stream.close() }
        let size = try stream.seekToEnd()
        for block in [parent, info, headers, keys, hits] {
            guard block.offset >= 8, block.offset <= size, block.length <= size - block.offset else {
                throw LegacyCompactPostingsError.invalidIndex(block.tag)
            }
            let header = try read(stream, offset: block.offset - 8, count: 8, fileSize: size)
            guard header.prefix(4).elementsEqual(block.tag.utf8), UInt64(u32(Array(header), 4)) == block.length else {
                throw LegacyCompactPostingsError.invalidIndex(block.tag)
            }
        }
        guard info.length == 8 else { throw LegacyCompactPostingsError.invalidIndex("WIDX/info") }
        let infoBytes = Array(try read(stream, offset: info.offset, count: 8, fileSize: size))
        guard u16(infoBytes, 0) == 0 else { throw LegacyCompactPostingsError.invalidIndex("WIDX/version") }
        let declaredRows = u32(infoBytes, 2)
        guard UInt64(declaredRows) <= UInt64(limits.maximumDictionaryRows) else { throw LegacyCompactPostingsError.limitExceeded }
        let rowCount = Int(declaredRows)
        guard UInt64(rowCount) * 12 == headers.length else { throw LegacyCompactPostingsError.invalidIndex("WIDX/hlst") }
        guard dictionaryRow >= 0, dictionaryRow < rowCount else { throw LegacyCompactPostingsError.dictionaryRowNotFound(dictionaryRow) }
        let hasNext = dictionaryRow + 1 < rowCount
        let row = Array(try read(stream, offset: headers.offset + UInt64(dictionaryRow) * 12, count: hasNext ? 24 : 12, fileSize: size))
        let keyAt = UInt64(u32(row, 0)), hitAt = UInt64(u32(row, 4)), expectedHits = u32(row, 8)
        let keyEnd = hasNext ? UInt64(u32(row, 12)) : keys.length
        let hitEnd = hasNext ? UInt64(u32(row, 16)) : hits.length
        guard keyAt <= keyEnd, keyEnd <= keys.length, hitAt < hitEnd, hitEnd <= hits.length else {
            throw LegacyCompactPostingsError.invalidIndex("WIDX/row offsets")
        }
        guard keyEnd - keyAt <= UInt64(limits.maximumKeyBytes), hitEnd - hitAt <= UInt64(limits.maximumPacketBytes),
              UInt64(expectedHits) <= UInt64(limits.maximumHits) else { throw LegacyCompactPostingsError.limitExceeded }
        let key = try read(stream, offset: keys.offset + keyAt, count: Int(keyEnd - keyAt), fileSize: size)
        let packet = try read(stream, offset: hits.offset + hitAt, count: Int(hitEnd - hitAt), fileSize: size)
        let decoded = try decodePacket(packet, expectedHitCount: expectedHits, limits: limits)
        try Task.checkCancellation()
        return .init(indexOrdinal: indexOrdinal, parentFileOffset: parent.offset, dictionaryRow: dictionaryRow,
            dictionaryKeyBytes: key, indexInfoWord: u16(infoBytes, 6), packetFileOffset: hits.offset + hitAt,
            packetByteCount: packet.count, postings: decoded)
    }

    /// Supported outer framing; strict tails/counts/budgets are reconstruction policies.
    public static func decodePacket(_ packet: Data, expectedHitCount: UInt32,
                                     limits: LegacyCompactPostingsLimits = .init()) throws -> LegacyCompactPostings {
        guard limits.valid else { throw LegacyCompactPostingsError.invalidLimits }
        guard packet.count <= limits.maximumPacketBytes, UInt64(expectedHitCount) <= UInt64(limits.maximumHits) else {
            throw LegacyCompactPostingsError.limitExceeded
        }
        try Task.checkCancellation()
        let bytes = Array(packet)
        guard bytes.count >= 9 else { throw LegacyCompactPostingsError.invalidPacket }
        let external = u16(bytes, 0), mode = u16(bytes, 2), hint = Int(u16(bytes, 4))
        guard external == 0, mode == 1 else { throw LegacyCompactPostingsError.unsupportedStream(external: external, mode: mode) }
        guard hint > 0 else { throw LegacyCompactPostingsError.invalidPacket }
        var at = 6, blocks = 0, decoded = Data()
        while at < bytes.count {
            try Task.checkCancellation()
            guard blocks < limits.maximumBlocks else { throw LegacyCompactPostingsError.limitExceeded }
            guard 3 <= bytes.count - at else { throw LegacyCompactPostingsError.invalidPacket }
            let compressed = bytes[at] != 0, packed = u16(bytes, at + 1)
            let count = Int(packed & 0x7fff), last = packed & 0x8000 != 0
            at += 3
            guard count > 0, count <= bytes.count - at else { throw LegacyCompactPostingsError.invalidPacket }
            let stored = Data(bytes[at..<(at + count)]), remaining = limits.maximumDecodedBytes - decoded.count
            let block: Data
            if compressed { block = try decompress(stored, initialCapacity: hint, maximumCapacity: remaining) }
            else {
                guard count <= remaining else { throw LegacyCompactPostingsError.limitExceeded }
                block = stored
            }
            decoded.append(block); at += count; blocks += 1
            if last {
                guard at == bytes.count else { throw LegacyCompactPostingsError.trailingData }
                return try decodeNumericPayload(decoded, expectedHitCount: expectedHitCount, limits: limits)
            }
        }
        throw LegacyCompactPostingsError.invalidPacket
    }

    public static func decodeNumericPayload(_ payload: Data, expectedHitCount: UInt32,
                                             limits: LegacyCompactPostingsLimits = .init()) throws -> LegacyCompactPostings {
        guard limits.valid else { throw LegacyCompactPostingsError.invalidLimits }
        guard payload.count <= limits.maximumDecodedBytes, UInt64(expectedHitCount) <= UInt64(limits.maximumHits) else {
            throw LegacyCompactPostingsError.limitExceeded
        }
        try Task.checkCancellation()
        let bytes = Array(payload)
        guard bytes.count >= 4 else { throw LegacyCompactPostingsError.invalidNumericPayload }
        let metadata = u32(bytes, 0)
        var at = 4, total = 0, groups: [LegacyCompactPostingGroup] = []
        while total < Int(expectedHitCount) {
            try Task.checkCancellation()
            guard groups.count < limits.maximumGroups else { throw LegacyCompactPostingsError.limitExceeded }
            guard 6 <= bytes.count - at else { throw LegacyCompactPostingsError.invalidNumericPayload }
            let groupAt = at, article = u32(bytes, at), signedCount = Int16(bitPattern: u16(bytes, at + 4))
            at += 6
            guard signedCount > 0 else { throw LegacyCompactPostingsError.invalidGroupCount(signedCount) }
            let count = Int(signedCount)
            guard count <= Int(expectedHitCount) - total, count <= (bytes.count - at) / 5 else {
                throw LegacyCompactPostingsError.invalidNumericPayload
            }
            var postings: [LegacyCompactPosting] = []
            postings.reserveCapacity(count)
            for ordinal in 0..<count {
                if ordinal % 256 == 0 { try Task.checkCancellation() }
                postings.append(.init(decodedOffset: at, positionBits: u32(bytes, at), extentBits: bytes[at + 4]))
                at += 5
            }
            groups.append(.init(decodedOffset: groupAt, articleBits: article, postings: postings)); total += count
        }
        guard at == bytes.count else { throw LegacyCompactPostingsError.trailingData }
        return .init(leadingMetadataWord: metadata, expectedHitCount: expectedHitCount, decodedByteCount: bytes.count, groups: groups)
    }

    private static func decompress(_ input: Data, initialCapacity: Int, maximumCapacity: Int) throws -> Data {
        guard maximumCapacity > 0 else { throw LegacyCompactPostingsError.limitExceeded }
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
                guard capacity < maximumCapacity else { throw LegacyCompactPostingsError.limitExceeded }
                capacity = min(capacity * 2, maximumCapacity); continue
            }
            guard status == 0 else { throw LegacyCompactPostingsError.decompressionFailed(Int32(status)) }
            guard written <= capacity else { throw LegacyCompactPostingsError.invalidPacket }
            output.count = written; return output
        }
        #else
        throw LegacyCompactPostingsError.decompressionFailed(-101)
        #endif
    }

    private static func read(_ stream: FileHandle, offset: UInt64, count: Int, fileSize: UInt64) throws -> Data {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else { throw LegacyCompactPostingsError.invalidPacket }
        try stream.seek(toOffset: offset)
        var bytes = Data()
        while bytes.count < count {
            try Task.checkCancellation()
            guard let part = try stream.read(upToCount: min(64 * 1024, count - bytes.count)), !part.isEmpty else {
                throw LegacyCompactPostingsError.invalidPacket
            }
            bytes.append(part)
        }
        return bytes
    }
    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { UInt32(u16(bytes, at)) | UInt32(u16(bytes, at + 2)) << 16 }
}
