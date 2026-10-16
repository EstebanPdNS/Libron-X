import Foundation

public struct LegacyBagEntry: Sendable, Codable, Equatable {
    public let name: String
    public let decodedLength: UInt32
    public let sourceFlags: UInt32
    public let ordinal: Int
    public let block: LegacyBlock
}

public struct LegacyBagCatalog: Sendable, Codable, Equatable {
    public let entries: [LegacyBagEntry]
    public let directoryStateWord: UInt32
    public let trailingDirectoryBytes: Int
}

public enum LegacyBagError: Error, LocalizedError, Equatable, Sendable {
    case invalidDirectory, invalidCompression, unsupportedCompression(UInt32)
    case unsupportedEntryFlags(UInt32), assetNotFound(String), assetLimit
    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "El directorio de imágenes BAGS no tiene una estructura válida."
        case .invalidCompression: "Los bloques comprimidos de la imagen no coinciden con sus límites y longitud."
        case let .unsupportedCompression(value): "El formato de compresión de imagen \(value) sigue pendiente."
        case let .unsupportedEntryFlags(value): "Los flags de la imagen \(value) siguen pendientes."
        case let .assetNotFound(name): "No se encontró la imagen \(name) dentro de este recurso."
        case .assetLimit: "La imagen supera el límite de tamaño del lector."
        }
    }
}

/// Resource-local BAGS/bdir/bagf. Originals are read-only and names are opaque
/// identifiers, never filesystem destinations. Only the measured stream shape
/// 0x20000001, with independent 8 KiB DCL blocks, is accepted by this decoder.
public enum LegacyBagReader {
    public static let maximumAssetBytes = 64 * 1_024 * 1_024

    public static func inspect(_ url: URL) throws -> LegacyBagCatalog {
        let blocks = try LegacyResourceReader.inspect(lsfURL: url).lsf.blocks
        let bags = blocks.filter { $0.tag == "BAGS" }, directories = blocks.filter { $0.tag == "bdir" }
        guard bags.count == 1, directories.count == 1 else { throw LegacyBagError.invalidDirectory }
        let group = bags[0], directory = directories[0], files = blocks.filter { $0.tag == "bagf" }
        // Keep the collection and bounds explicit for Swift 6.2's type checker.
        let members: [LegacyBlock] = [directory] + files
        let groupStart = group.offset + 8
        let groupEnd = group.offset + group.length
        guard directory.length <= 16 * 1_024 * 1_024,
              members.allSatisfy({ member in
                  member.offset >= groupStart && member.offset + member.length <= groupEnd
              }) else { throw LegacyBagError.invalidDirectory }
        return try decodeDirectory(readBlock(url, block: directory), files: files)
    }

    static func decodeDirectory(_ data: Data, files: [LegacyBlock]) throws -> LegacyBagCatalog {
        guard data.count >= 8 else { throw LegacyBagError.invalidDirectory }
        let count = Int(u32(data, 0))
        guard count > 0, count <= 65_535, count == files.count, count <= (data.count - 8) / 264 else {
            throw LegacyBagError.invalidDirectory
        }
        var names = Set<String>(), entries: [LegacyBagEntry] = []
        for ordinal in 0..<count {
            try Task.checkCancellation()
            let start = 8 + ordinal * 264
            let bytes = data[(start + 8)..<(start + 264)]
            guard let end = bytes.firstIndex(of: 0), end > start + 8 else { throw LegacyBagError.invalidDirectory }
            let name = LegacyResourceReader.decodeCP1252(bytes[..<end])
            // Case-insensitive lookup is observed in the original bag/cache code.
            guard names.insert(name.lowercased()).inserted else { throw LegacyBagError.invalidDirectory }
            entries.append(.init(name: name, decodedLength: u32(data, start), sourceFlags: u32(data, start + 4),
                                 ordinal: ordinal, block: files[ordinal]))
        }
        return .init(entries: entries, directoryStateWord: u32(data, 4), trailingDirectoryBytes: data.count - 8 - count * 264)
    }

    public static func read(_ url: URL, catalog: LegacyBagCatalog, name: String,
                            maximumBytes: Int = maximumAssetBytes) throws -> Data {
        guard let entry = catalog.entries.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
            throw LegacyBagError.assetNotFound(name)
        }
        guard entry.sourceFlags == 0 else { throw LegacyBagError.unsupportedEntryFlags(entry.sourceFlags) }
        guard maximumBytes > 0, maximumBytes <= maximumAssetBytes,
              entry.decodedLength > 0, entry.decodedLength <= maximumBytes,
              entry.block.length <= maximumAssetBytes * 2 else { throw LegacyBagError.assetLimit }
        return try decodeCompressed(readBlock(url, block: entry.block), expectedLength: Int(entry.decodedLength))
    }

    static func decodeCompressed(_ data: Data, expectedLength: Int) throws -> Data {
        guard expectedLength > 0, expectedLength <= maximumAssetBytes else { throw LegacyBagError.assetLimit }
        guard data.count >= 8 else { throw LegacyBagError.invalidCompression }
        let format = u32(data, 0)
        guard format == 0x20000001 else { throw LegacyBagError.unsupportedCompression(format) }
        let count = Int(u16(data, 4)), last = Int(u16(data, 6))
        guard count > 0, count <= (data.count - 8) / 2, last > 0, last <= 8192,
              (count - 1) * 8192 + last == expectedLength else { throw LegacyBagError.invalidCompression }
        var cursor = 8 + count * 2
        var output = Data(capacity: expectedLength)
        for ordinal in 0..<count {
            try Task.checkCancellation()
            let stored = Int(u16(data, 8 + ordinal * 2)), decoded = ordinal + 1 == count ? last : 8192
            guard stored > 0, cursor <= data.count, stored <= data.count - cursor else { throw LegacyBagError.invalidCompression }
            output.append(try LegacyContentReader.decompressDCL(data.subdata(in: cursor..<(cursor + stored)), expectedLength: decoded))
            cursor += stored
        }
        guard cursor == data.count, output.count == expectedLength else { throw LegacyBagError.invalidCompression }
        return output
    }

    private static func readBlock(_ url: URL, block: LegacyBlock) throws -> Data {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        let size = try stream.seekToEnd()
        guard block.offset >= 8, block.offset <= size, block.length <= size - block.offset else { throw LegacyBagError.invalidDirectory }
        try stream.seek(toOffset: block.offset - 8)
        guard let header = try stream.read(upToCount: 8), header.count == 8,
              String(decoding: header.prefix(4), as: UTF8.self) == block.tag,
              UInt64(u32(header, 4)) == block.length else { throw LegacyBagError.invalidDirectory }
        guard let data = try stream.read(upToCount: Int(block.length)), data.count == Int(block.length) else {
            throw LegacyBagError.invalidDirectory
        }
        return data
    }
    private static func u16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) } }
}
