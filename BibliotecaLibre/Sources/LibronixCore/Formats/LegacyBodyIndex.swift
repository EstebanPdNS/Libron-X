import Foundation

/// Shared checked BWDX framing. File handles never escape the synchronous readers.
final class LegacyBodyIndex {
    struct Row {
        let ordinal: Int
        let keyStart: UInt64
        let keyEnd: UInt64
        let hitStart: UInt64
        let hitEnd: UInt64
        let expectedHitCount: UInt32
    }

    let stream: FileHandle
    let fileSize: UInt64
    let rowCount: Int
    let indexInfoWord: UInt16
    let headers: LegacyBlock
    let keys: LegacyBlock
    let hits: LegacyBlock

    private init(stream: FileHandle, fileSize: UInt64, rowCount: Int,
                 indexInfoWord: UInt16, headers: LegacyBlock, keys: LegacyBlock, hits: LegacyBlock) {
        self.stream = stream; self.fileSize = fileSize; self.rowCount = rowCount
        self.indexInfoWord = indexInfoWord; self.headers = headers; self.keys = keys; self.hits = hits
    }

    static func open(lsfURL: URL, lixURL: URL, maximumRows: Int) throws -> LegacyBodyIndex {
        let pair = try LegacyResourceReader.inspect(lsfURL: lsfURL, lixURL: lixURL)
        guard pair.identifiersMatch == true, let metadata = pair.lix else {
            throw LegacyPostingsError.mismatchedPair
        }
        let candidates = metadata.blocks.filter { $0.tag == "BWDX" }
        guard candidates.count == 1, let parent = candidates.first else {
            throw LegacyPostingsError.missingBodyIndex
        }
        func child(_ tag: String) throws -> LegacyBlock {
            let rows = metadata.blocks.filter {
                $0.tag == tag && $0.offset >= parent.offset &&
                $0.length <= parent.length && $0.offset - parent.offset <= parent.length - $0.length
            }
            guard rows.count == 1, let row = rows.first else {
                throw LegacyPostingsError.invalidIndex("BWDX/" + tag)
            }
            return row
        }
        let info = try child("info"), headers = try child("hlst")
        let keys = try child("klst"), hits = try child("hits")
        let stream = try FileHandle(forReadingFrom: lixURL)
        var returned = false
        defer { if !returned { try? stream.close() } }
        let fileSize = try stream.seekToEnd()
        for block in [parent, info, headers, keys, hits] {
            guard block.offset >= 8, block.offset <= fileSize,
                  block.length <= fileSize - block.offset else {
                throw LegacyPostingsError.invalidIndex(block.tag)
            }
            let header = try read(stream, offset: block.offset - 8, count: 8, fileSize: fileSize)
            guard String(decoding: header.prefix(4), as: UTF8.self) == block.tag,
                  UInt64(u32(header, 4)) == block.length else {
                throw LegacyPostingsError.invalidIndex(block.tag)
            }
        }
        guard info.length == 8 else { throw LegacyPostingsError.invalidIndex("BWDX/info") }
        let words = try read(stream, offset: info.offset, count: 8, fileSize: fileSize)
        guard u16(words, 0) == 0 else { throw LegacyPostingsError.invalidIndex("BWDX/version") }
        let rows = Int(u32(words, 2))
        guard rows <= maximumRows else { throw LegacyPostingsError.limitExceeded }
        guard UInt64(rows) * 12 == headers.length else {
            throw LegacyPostingsError.invalidIndex("BWDX/hlst")
        }
        let result = LegacyBodyIndex(stream: stream, fileSize: fileSize, rowCount: rows,
            indexInfoWord: u16(words, 6), headers: headers, keys: keys, hits: hits)
        returned = true
        return result
    }

    deinit { try? stream.close() }

    func row(at ordinal: Int) throws -> Row {
        guard ordinal >= 0, ordinal < rowCount else {
            throw LegacyPostingsError.dictionaryRowNotFound(ordinal)
        }
        let hasNext = ordinal + 1 < rowCount
        let bytes = try read(offset: headers.offset + UInt64(ordinal) * 12, count: hasNext ? 24 : 12)
        return try row(at: ordinal, headerBytes: bytes, byteOffset: 0)
    }

    /// Also used by the bounded scan after reading the complete header table once.
    func row(at ordinal: Int, headerBytes: Data, byteOffset: Int) throws -> Row {
        let hasNext = ordinal + 1 < rowCount
        guard ordinal >= 0, ordinal < rowCount, byteOffset >= 0,
              byteOffset <= headerBytes.count,
              (hasNext ? 24 : 12) <= headerBytes.count - byteOffset else {
            throw LegacyPostingsError.invalidIndex("BWDX/hlst")
        }
        let keyStart = UInt64(Self.u32(headerBytes, byteOffset))
        let hitStart = UInt64(Self.u32(headerBytes, byteOffset + 4))
        let keyEnd = hasNext ? UInt64(Self.u32(headerBytes, byteOffset + 12)) : keys.length
        let hitEnd = hasNext ? UInt64(Self.u32(headerBytes, byteOffset + 16)) : hits.length
        guard keyStart <= keyEnd, keyEnd <= keys.length,
              hitStart < hitEnd, hitEnd <= hits.length else {
            throw LegacyPostingsError.invalidIndex("BWDX/row offsets")
        }
        return Row(ordinal: ordinal, keyStart: keyStart, keyEnd: keyEnd,
                   hitStart: hitStart, hitEnd: hitEnd,
                   expectedHitCount: Self.u32(headerBytes, byteOffset + 8))
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        try Self.read(stream, offset: offset, count: count, fileSize: fileSize)
    }

    private static func read(_ stream: FileHandle, offset: UInt64, count: Int, fileSize: UInt64) throws -> Data {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw LegacyPostingsError.invalidPacket
        }
        try stream.seek(toOffset: offset)
        var result = Data()
        while result.count < count {
            guard let part = try stream.read(upToCount: count - result.count), !part.isEmpty else {
                throw LegacyPostingsError.invalidPacket
            }
            result.append(part)
        }
        return result
    }

    static func u16(_ bytes: Data, _ at: Int) -> UInt16 {
        UInt16(bytes[bytes.startIndex + at]) | UInt16(bytes[bytes.startIndex + at + 1]) << 8
    }
    static func u32(_ bytes: Data, _ at: Int) -> UInt32 {
        UInt32(bytes[bytes.startIndex + at]) | UInt32(bytes[bytes.startIndex + at + 1]) << 8 |
        UInt32(bytes[bytes.startIndex + at + 2]) << 16 | UInt32(bytes[bytes.startIndex + at + 3]) << 24
    }
}
