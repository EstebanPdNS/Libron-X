import Foundation

/// One source-ordered RTAX/hlst row. The four DWORDs stay in the original
/// index domain; neither their physical unit nor a universal datatype is assigned.
public struct LegacyReferenceMapRow: Sendable, Codable, Equatable {
    public let row: Int
    public let recordOffset: Int
    public let referenceKeyBits: UInt16
    public let startArticleBits: UInt32
    public let startPositionBits: UInt32
    public let endArticleBits: UInt32
    public let endPositionBits: UInt32
    /// Exactly the 18 original row bytes, including the packed u16 key.
    public let rawBytes: Data
}

public struct LegacyReferenceMap: Sendable, Equatable {
    public let infoHeaderWord: UInt16
    public let declaredRowCount: UInt32
    public let rawInfoBytes: Data
    public let rows: [LegacyReferenceMapRow]
    /// Nil for decodeTable fixtures; otherwise the original hlst payload offset.
    public let recordPayloadFileOffset: UInt64?
    private let rowsByKey: [UInt16: [Int]]

    fileprivate init(info: Data, rows: [LegacyReferenceMapRow], payloadOffset: UInt64?) {
        self.infoHeaderWord = 0
        self.declaredRowCount = UInt32(rows.count)
        self.rawInfoBytes = info
        self.rows = rows
        self.recordPayloadFileOffset = payloadOffset
        self.rowsByKey = Dictionary(grouping: rows.indices, by: { rows[$0].referenceKeyBits })
    }

    /// Missing and duplicate keys cannot fabricate a successful native context.
    /// Duplicate rejection is a reconstruction policy; native tie choice is unproved.
    public func lookup(referenceKey: UInt16) throws -> LegacyReferenceMapRow {
        guard let indices = rowsByKey[referenceKey] else {
            throw LegacyReferenceMapError.missingReferenceKey(referenceKey)
        }
        guard indices.count == 1 else {
            throw LegacyReferenceMapError.ambiguousReferenceKey(referenceKey, matches: indices.count)
        }
        return rows[indices[0]]
    }

    public func project(referenceKey: UInt16, articleBits: UInt32, positionBits: UInt32,
                        extentBits: UInt32) throws -> LegacyReferenceProjection {
        LegacyReferenceProjection.make(entry: try lookup(referenceKey: referenceKey),
            articleBits: articleBits, positionBits: positionBits, extentBits: extentBits)
    }
}

/// Scalar projection for the byte-bound successful RTAX lookup branch only.
/// It is not a complete result node, source-text range, containment check or evaluator.
public struct LegacyReferenceProjection: Sendable, Codable, Equatable {
    public let referenceKeyBits: UInt16
    public let referenceRow: Int
    public let parentArticleBits: UInt32
    public let parentOriginBits: UInt32
    public let positionBits: UInt32
    public let extentBits: UInt32
    public let articleDeltaBits: UInt32

    /// The proven suffix serialization; full public-node equality remains unverified.
    public var olaSuffix: String {
        "::OLA:\(positionBits).\(extentBits).\(articleDeltaBits)"
    }

    public static func make(entry: LegacyReferenceMapRow, articleBits: UInt32,
                            positionBits: UInt32, extentBits: UInt32) -> Self {
        let delta = articleBits &- entry.startArticleBits
        let projected = delta == 0 && positionBits > entry.startPositionBits
            ? positionBits &- entry.startPositionBits : positionBits
        return Self(referenceKeyBits: entry.referenceKeyBits, referenceRow: entry.row,
                    parentArticleBits: entry.startArticleBits, parentOriginBits: entry.startPositionBits,
                    positionBits: projected, extentBits: extentBits, articleDeltaBits: delta)
    }
}

public struct LegacyReferenceMapLimits: Sendable, Equatable {
    public var maximumRows: Int
    public var maximumRecordBytes: Int

    public init(maximumRows: Int = 500_000, maximumRecordBytes: Int = 16 * 1024 * 1024) {
        self.maximumRows = maximumRows
        self.maximumRecordBytes = maximumRecordBytes
    }

    fileprivate var valid: Bool {
        (0...1_000_000).contains(maximumRows) &&
        (0...32 * 1024 * 1024).contains(maximumRecordBytes)
    }
}

public enum LegacyReferenceMapError: Error, Sendable, Equatable, LocalizedError {
    case invalidLimits
    case limitExceeded
    case pairIdentifiersUnavailable
    case mismatchedPair
    case missingReferenceMap
    case ambiguousReferenceMap
    case invalidTable(String)
    case unsupportedInfoHeaderWord(UInt16)
    case missingReferenceKey(UInt16)
    case ambiguousReferenceKey(UInt16, matches: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "The reference-map limits are invalid."
        case .limitExceeded: "The reference map exceeds the configured reconstruction limits."
        case .pairIdentifiersUnavailable: "The LSF and LIX identifiers cannot be compared."
        case .mismatchedPair: "The LSF and LIX identifiers do not match."
        case .missingReferenceMap: "The LIX has no RTAX reference map."
        case .ambiguousReferenceMap: "The LIX has multiple RTAX reference maps."
        case let .invalidTable(tag): "The reference-map table is inconsistent: \(tag)."
        case let .unsupportedInfoHeaderWord(word): "Unsupported RTAX info header word: \(word)."
        case let .missingReferenceKey(key): "RTAX reference key \(key) was not found."
        case let .ambiguousReferenceKey(key, matches): "RTAX reference key \(key) has \(matches) rows; native tie choice is unverified."
        }
    }
}

public enum LegacyReferenceMapReader {
    /// Reads only the checked RTAX table; originals are never modified.
    /// Source order, duplicate keys and all coordinate bits are retained.
    public static func read(lsfURL: URL, lixURL: URL,
                            limits: LegacyReferenceMapLimits = .init()) throws -> LegacyReferenceMap {
        guard limits.valid else { throw LegacyReferenceMapError.invalidLimits }
        try Task.checkCancellation()
        let pair = try LegacyResourceReader.inspect(lsfURL: lsfURL, lixURL: lixURL)
        guard let matches = pair.identifiersMatch, let metadata = pair.lix else {
            throw LegacyReferenceMapError.pairIdentifiersUnavailable
        }
        guard matches else { throw LegacyReferenceMapError.mismatchedPair }
        let parents = metadata.blocks.filter { $0.tag == "RTAX" }
        guard !parents.isEmpty else { throw LegacyReferenceMapError.missingReferenceMap }
        guard parents.count == 1 else { throw LegacyReferenceMapError.ambiguousReferenceMap }
        let parent = parents[0]
        func child(_ tag: String) throws -> LegacyBlock {
            let matches = metadata.blocks.filter {
                $0.tag == tag && $0.offset >= parent.offset && $0.offset - parent.offset >= 8 &&
                $0.length <= parent.length && $0.offset - parent.offset <= parent.length - $0.length
            }
            guard matches.count == 1 else { throw LegacyReferenceMapError.invalidTable("RTAX/" + tag) }
            return matches[0]
        }
        let info = try child("info"), records = try child("hlst")
        let stream = try FileHandle(forReadingFrom: lixURL)
        defer { try? stream.close() }
        let fileSize = try stream.seekToEnd()
        for block in [parent, info, records] {
            guard block.offset >= 8, block.offset <= fileSize, block.length <= fileSize - block.offset else {
                throw LegacyReferenceMapError.invalidTable(block.tag)
            }
            let header = try readBytes(stream, offset: block.offset - 8, count: 8, fileSize: fileSize)
            let bytes = [UInt8](header)
            guard String(decoding: bytes[0..<4], as: UTF8.self) == block.tag,
                  UInt64(u32(bytes, 4)) == block.length else {
                throw LegacyReferenceMapError.invalidTable(block.tag)
            }
        }
        guard info.length == 6 else { throw LegacyReferenceMapError.invalidTable("RTAX/info") }
        let infoBytes = try readBytes(stream, offset: info.offset, count: 6, fileSize: fileSize)
        let count = try validateInfo(infoBytes, recordByteCount: records.length, limits: limits)
        let recordBytes = try readBytes(stream, offset: records.offset, count: UInt64(count) * 18, fileSize: fileSize)
        return try parse(info: infoBytes, records: recordBytes, payloadOffset: records.offset, limits: limits)
    }

    public static func decodeTable(info: Data, records: Data,
                                   limits: LegacyReferenceMapLimits = .init()) throws -> LegacyReferenceMap {
        try parse(info: info, records: records, payloadOffset: nil, limits: limits)
    }

    private static func parse(info: Data, records: Data, payloadOffset: UInt64?,
                              limits: LegacyReferenceMapLimits) throws -> LegacyReferenceMap {
        guard limits.valid else { throw LegacyReferenceMapError.invalidLimits }
        try Task.checkCancellation()
        let count = try validateInfo(info, recordByteCount: UInt64(records.count), limits: limits)
        let bytes = [UInt8](records)
        var rows: [LegacyReferenceMapRow] = []
        rows.reserveCapacity(Int(count))
        for row in 0..<Int(count) {
            try Task.checkCancellation()
            let at = row * 18
            rows.append(LegacyReferenceMapRow(row: row, recordOffset: at, referenceKeyBits: u16(bytes, at),
                startArticleBits: u32(bytes, at + 2), startPositionBits: u32(bytes, at + 6),
                endArticleBits: u32(bytes, at + 10), endPositionBits: u32(bytes, at + 14),
                rawBytes: Data(bytes[at..<(at + 18)])))
        }
        return LegacyReferenceMap(info: Data([UInt8](info)), rows: rows, payloadOffset: payloadOffset)
    }

    private static func validateInfo(_ info: Data, recordByteCount: UInt64,
                                     limits: LegacyReferenceMapLimits) throws -> UInt32 {
        guard info.count == 6 else { throw LegacyReferenceMapError.invalidTable("RTAX/info") }
        let bytes = [UInt8](info), word = u16(bytes, 0), count = u32(bytes, 2)
        guard word == 0 else { throw LegacyReferenceMapError.unsupportedInfoHeaderWord(word) }
        guard UInt64(count) <= UInt64(limits.maximumRows),
              recordByteCount <= UInt64(limits.maximumRecordBytes) else {
            throw LegacyReferenceMapError.limitExceeded
        }
        guard UInt64(count) * 18 == recordByteCount else {
            throw LegacyReferenceMapError.invalidTable("RTAX/hlst")
        }
        return count
    }

    private static func readBytes(_ stream: FileHandle, offset: UInt64, count: UInt64,
                                  fileSize: UInt64) throws -> Data {
        guard offset <= fileSize, count <= fileSize - offset, count <= UInt64(Int.max) else {
            throw LegacyReferenceMapError.invalidTable("read range")
        }
        try stream.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(Int(count))
        while result.count < Int(count) {
            try Task.checkCancellation()
            guard let part = try stream.read(upToCount: min(1024 * 1024, Int(count) - result.count)), !part.isEmpty else {
                throw LegacyReferenceMapError.invalidTable("incomplete read")
            }
            result.append(part)
        }
        return result
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
