import Foundation
import CLibronxCompression

/// Caller-supplied format context. No proprietary context is compiled into the app.
/// Deliberately not Codable; descriptions never expose the four words.
public struct LTESKeyMaterial: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let words: [UInt32]

    public init(words: [UInt32]) throws {
        guard words.count == 4 else { throw LTESReadError.invalidContextShape }
        self.words = words
    }

    public var description: String { "LTESKeyMaterial(redacted)" }
    public var debugDescription: String { description }
}

public protocol LTESConfigurationKeyProvider: Sendable {
    func context(forConfigurationAt url: URL) throws -> LTESKeyMaterial
}

public enum LTESReadError: Error, Sendable, Equatable, LocalizedError {
    case invalidContextShape, unsupportedConfiguration, invalidLTES, unsupportedVersion
    case contextMismatch, limitExceeded, invalidLZCS, invalidLEFS, invalidDirectory
    case entryNotFound, zlibFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidContextShape: "El contexto LTES debe contener cuatro palabras de 32 bits."
        case .unsupportedConfiguration: "El lector LTES sólo admite los contenedores de configuración demostrados."
        case .invalidLTES: "La cabecera o longitud del envoltorio LTES es inválida."
        case .unsupportedVersion: "La versión del envoltorio no ha sido validada."
        case .contextMismatch: "El contexto externo no coincide con la comprobación del contenedor."
        case .limitExceeded: "El contenedor supera los límites de lectura."
        case .invalidLZCS: "El índice o bloque comprimido LZCS es inválido."
        case .invalidLEFS: "El archivo LEFS no contiene una cabecera de configuración admitida."
        case .invalidDirectory: "El directorio LEFS es inválido o contiene un ciclo."
        case .entryNotFound: "La entrada solicitada no existe en el contenedor."
        case let .zlibFailure(code): "El bloque zlib no se pudo validar (\(code))."
        }
    }
}

public struct LTESArchiveEntry: Sendable, Codable, Equatable {
    public let path: String
    public let offset: UInt64
    public let length: UInt64
}

/// Read-only data from a configuration package. Scripts are bytes, never executed.
public struct LTESConfigurationArchive: Sendable {
    public let metadata: XMLNode
    public let entries: [LTESArchiveEntry]
    public let directoryCount: Int
    public let compressedBlockCount: Int
    public let decodedByteCount: Int
    private let bytes: Data

    fileprivate init(metadata: XMLNode, entries: [LTESArchiveEntry], directoryCount: Int,
                     compressedBlockCount: Int, bytes: Data) {
        self.metadata = metadata
        self.entries = entries
        self.directoryCount = directoryCount
        self.compressedBlockCount = compressedBlockCount
        self.decodedByteCount = bytes.count
        self.bytes = bytes
    }

    public func readEntry(path: String, maximumBytes: Int = 1_048_576) throws -> Data {
        guard let entry = entries.first(where: { $0.path == path }) else { throw LTESReadError.entryNotFound }
        guard maximumBytes >= 0, entry.length <= UInt64(maximumBytes) else { throw LTESReadError.limitExceeded }
        return bytes.subdata(in: Int(entry.offset)..<Int(entry.offset + entry.length))
    }
}

/// Reimplementation of the observed configuration wrapper, not a book or license reader.
/// Supports validated LTES 1.1, indexed LZCS 1.0 and LEFS 1.0 only.
public enum LTESContainerReader {
    public static let maximumContainerBytes = 64 * 1024 * 1024
    private static let maximumEntries = 20_000
    private static let maximumDepth = 32
    private static let extensions: Set<String> = ["lbxcmp", "lbxrtp", "lbxadd", "lbxshl"]

    public static func inspectConfiguration(at url: URL,
        provider: any LTESConfigurationKeyProvider) throws -> LTESConfigurationArchive {
        guard extensions.contains(url.pathExtension.lowercased()) else { throw LTESReadError.unsupportedConfiguration }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(maximumContainerBytes), size >= 24 else { throw LTESReadError.limitExceeded }
        try handle.seek(toOffset: 0)
        guard let data = try handle.read(upToCount: Int(size)), data.count == Int(size) else { throw LTESReadError.invalidLTES }
        return try decodeConfiguration(data, context: provider.context(forConfigurationAt: url))
    }

    /// The context must come from the caller; this API cannot infer entitlement.
    public static func decodeConfiguration(_ encrypted: Data, context: LTESKeyMaterial) throws -> LTESConfigurationArchive {
        let compressed = try decodeLTES(encrypted, context: context)
        let (archive, blocks) = try decodeLZCS(compressed)
        return try decodeLEFS(archive, compressedBlocks: blocks)
    }

    private static func decodeLTES(_ input: Data, context: LTESKeyMaterial) throws -> Data {
        let b = [UInt8](input)
        guard b.count <= maximumContainerBytes else { throw LTESReadError.limitExceeded }
        guard b.count >= 24, Array(b[0..<4]) == Array("LTES".utf8), (b.count - 16) % 8 == 0 else { throw LTESReadError.invalidLTES }
        guard u32(b, 4) == 0x0101_0000 else { throw LTESReadError.unsupportedVersion }
        let declared = u64(b, 8)
        guard declared <= UInt64(maximumContainerBytes) else { throw LTESReadError.limitExceeded }
        guard declared <= UInt64(b.count - 24), UInt64(b.count - 24) - declared <= 7 else { throw LTESReadError.invalidLTES }
        var clear = [UInt8](); clear.reserveCapacity(b.count - 16)
        for start in stride(from: 16, to: b.count, by: 8) {
            var a = u32(b, start), v = u32(b, start + 4)
            var sum = UInt32(8) &* 0x9e37_79b9
            for _ in 0..<8 {
                v = v &- ((((a << 4) ^ (a >> 5)) &+ a) ^ (sum &+ context.words[Int((sum >> 11) & 3)]))
                sum = sum &- 0x9e37_79b9
                a = a &- ((((v << 4) ^ (v >> 5)) &+ v) ^ (sum &+ context.words[Int(sum & 3)]))
            }
            for word in [a, v] { for shift in stride(from: 0, to: 32, by: 8) { clear.append(UInt8(truncatingIfNeeded: word >> shift)) } }
        }
        guard clear[0..<8].elementsEqual(b[0..<8]) else { throw LTESReadError.contextMismatch }
        return Data(clear[8..<(8 + Int(declared))])
    }

    static func decodeLZCS(_ input: Data) throws -> (Data, Int) {
        let b = [UInt8](input)
        guard b.count >= 36, Array(b[0..<4]) == Array("LZCS".utf8) else { throw LTESReadError.invalidLZCS }
        guard u32(b, 4) == 0x0100_0000 else { throw LTESReadError.unsupportedVersion }
        let extra = UInt64(u32(b, 8)), logical = u64(b, 12)
        let exponent = u32(b, 20), record = u32(b, 24), index = u64(b, 28)
        guard extra == 24, exponent <= 20, record == 12, logical <= UInt64(maximumContainerBytes),
              index >= 12 + extra, index <= UInt64(b.count) else { throw LTESReadError.invalidLZCS }
        let rawCount = index - 12 - extra
        guard rawCount <= logical else { throw LTESReadError.invalidLZCS }
        let remaining = logical - rawCount, blockSize = UInt64(1) << exponent
        let count = (remaining + blockSize - 1) / blockSize
        guard count <= UInt64(maximumEntries), count <= (UInt64(b.count) - index) / 12 else { throw LTESReadError.invalidLZCS }
        let indexEnd = index + count * 12
        var output = Data(b[36..<Int(index)]); output.reserveCapacity(Int(logical))
        var ranges: [(UInt64, UInt64)] = []
        for i in 0..<Int(count) {
            let entry = Int(index) + 12 * i
            let offset = u64(b, entry), stored = UInt64(u32(b, entry + 8))
            let expected = Int(min(blockSize, remaining - UInt64(i) * blockSize))
            guard offset >= indexEnd, offset <= UInt64(b.count), stored > 0,
                  stored <= UInt64(b.count) - offset else { throw LTESReadError.invalidLZCS }
            ranges.append((offset, offset + stored))
            var destination = [UInt8](repeating: 0, count: expected)
            var written = 0
            let status = b.withUnsafeBufferPointer { source in
                destination.withUnsafeMutableBufferPointer { target in
                    libronx_inflate_zlib(source.baseAddress! + Int(offset), Int(stored),
                                        target.baseAddress!, expected, &written)
                }
            }
            guard status == 0 else { throw LTESReadError.zlibFailure(status) }
            guard written == expected else { throw LTESReadError.invalidLZCS }
            output.append(contentsOf: destination)
        }
        ranges.sort { $0.0 < $1.0 }
        for i in 1..<max(1, ranges.count) where ranges[i - 1].1 > ranges[i].0 { throw LTESReadError.invalidLZCS }
        guard output.count == Int(logical) else { throw LTESReadError.invalidLZCS }
        return (output, Int(count))
    }

    private static func decodeLEFS(_ input: Data, compressedBlocks: Int) throws -> LTESConfigurationArchive {
        let b = [UInt8](input)
        guard b.count >= 56, Array(b[0..<4]) == Array("LEFS".utf8), u32(b, 4) == 0x0100_0000,
              u32(b, 28) == 20 else { throw LTESReadError.invalidLEFS }
        let xmlBytes = u64(b, 20)
        guard xmlBytes <= UInt64(MetadataXMLReader.maximumFileBytes), xmlBytes <= UInt64(b.count - 56) else { throw LTESReadError.invalidLEFS }
        let rootDirectory = 32 + Int(xmlBytes)
        let metadata = try MetadataXMLReader.parse(Data(b[32..<rootDirectory]))
        guard ["lbx-company", "lbx-resource-type", "lbx-user-interface"].contains(metadata.name) else { throw LTESReadError.unsupportedConfiguration }
        let dataStart = u64(b, rootDirectory), nameSlots = u32(b, rootDirectory + 16)
        guard u32(b, rootDirectory + 12) == 16, nameSlots > 0, nameSlots <= 2048,
              dataStart <= UInt64(b.count), dataStart >= UInt64(rootDirectory + 24) else { throw LTESReadError.invalidDirectory }
        let strideBytes = 16 + Int(nameSlots) * 2
        var entries: [LTESArchiveEntry] = [], seenOffsets: Set<Int> = [], seenPaths: Set<String> = []
        var directoryRanges: [(Int, Int)] = []
        var directoryCount = 0
        func readDirectory(_ offset: Int, prefix: String, depth: Int, root: Bool) throws {
            guard depth <= maximumDepth, seenOffsets.insert(offset).inserted,
                  offset >= rootDirectory, offset <= Int(dataStart) - (root ? 24 : 4) else { throw LTESReadError.invalidDirectory }
            let header = root ? 24 : 4
            let count = Int(u32(b, offset + (root ? 20 : 0)))
            guard count <= maximumEntries, count <= (Int(dataStart) - offset - header) / strideBytes,
                  entries.count + count <= maximumEntries else { throw LTESReadError.limitExceeded }
            let end = offset + header + count * strideBytes
            directoryRanges.append((offset, end)); directoryCount += root ? 0 : 1
            for i in 0..<count {
                let record = offset + header + i * strideBytes
                let start = u64(b, record), size = u64(b, record + 8)
                let nameBytes = Data(b[(record + 16)..<(record + strideBytes)])
                guard let fullName = String(data: nameBytes, encoding: .utf16LittleEndian),
                      let nul = fullName.firstIndex(of: "\0") else { throw LTESReadError.invalidDirectory }
                let name = String(fullName[..<nul])
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                      !name.unicodeScalars.contains(where: { $0.value < 32 }), start <= UInt64(b.count),
                      size <= UInt64(b.count) - start else { throw LTESReadError.invalidDirectory }
                let path = prefix + name
                guard seenPaths.insert(path).inserted else { throw LTESReadError.invalidDirectory }
                guard seenPaths.count <= maximumEntries else { throw LTESReadError.limitExceeded }
                if start < dataStart {
                    guard size == 0 else { throw LTESReadError.invalidDirectory }
                    try readDirectory(Int(start), prefix: path + "/", depth: depth + 1, root: false)
                } else {
                    entries.append(LTESArchiveEntry(path: path, offset: start, length: size))
                }
            }
        }
        try readDirectory(rootDirectory, prefix: "", depth: 0, root: true)
        directoryRanges.sort { $0.0 < $1.0 }
        for i in 1..<directoryRanges.count {
            guard directoryRanges[i - 1].1 == directoryRanges[i].0 else { throw LTESReadError.invalidDirectory }
        }
        guard directoryRanges.last?.1 == Int(dataStart) else { throw LTESReadError.invalidDirectory }
        return LTESConfigurationArchive(metadata: metadata, entries: entries, directoryCount: directoryCount,
                                        compressedBlockCount: compressedBlocks, bytes: input)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32
    }
}
