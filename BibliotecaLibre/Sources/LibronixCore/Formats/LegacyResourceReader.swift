import Foundation

/// A directory entry observed in the public LSFF container structure.
/// Tag names and flags are preserved without guessing their semantic meaning.
public struct LegacyBlock: Sendable, Codable, Equatable {
    public let tag: String
    public let offset: UInt64
    public let length: UInt64
    public let declaredChildren: UInt16
    public let flags: UInt32
}

/// Metadata only: this reader does not decompress book text or read LTES files.
public struct LegacyMetadata: Sendable, Codable, Equatable {
    public let title: String?
    public let marcTitle: String?
    public let uniformTitle: String?
    public let author: String?
    public let responsibility: String?
    public let declaredLanguages: [String]
    public let publisher: String?
    public let publication: String?
    public let bkidHex: String?
    public let blocks: [LegacyBlock]
}

public struct LegacyPairInspection: Sendable, Codable, Equatable {
    public let lsf: LegacyMetadata
    public let lix: LegacyMetadata?
    /// Nil means the identifiers could not be compared or no LIX was supplied.
    public let identifiersMatch: Bool?
    public let warnings: [String]

    public var title: String? { lsf.title ?? lsf.marcTitle }
}

public enum LegacyReaderError: Error, Sendable, Equatable, LocalizedError {
    case invalidSignature
    case wrongResourceType(expected: String, actual: String)
    case declaredSizeMismatch
    case invalidDirectory
    case directoryLimitExceeded
    case invalidRange(tag: String)
    case invalidMetadata(tag: String)
    case readLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidSignature: "El archivo no tiene la firma LSFF esperada."
        case let .wrongResourceType(expected, actual): "Tipo LSFF incorrecto: se esperaba \(expected) y se encontró \(actual)."
        case .declaredSizeMismatch: "El tamaño declarado del contenedor no coincide con el archivo."
        case .invalidDirectory: "El directorio de bloques LSFF no tiene una estructura válida."
        case .directoryLimitExceeded: "El directorio LSFF supera el límite de lectura segura."
        case let .invalidRange(tag): "El bloque \(tag) declara un rango fuera del archivo."
        case let .invalidMetadata(tag): "La cabecera del bloque de metadatos \(tag) no coincide con el directorio."
        case .readLimitExceeded: "El bloque solicitado supera el límite de metadatos del lector."
        }
    }
}

public enum LegacyResourceReader {
    /// Reads public metadata and checks directory bounds. Originals are read-only.
    /// LSF/LIX pair identifiers are compared without assigning undocumented IDs.
    public static func inspect(lsfURL: URL, lixURL: URL? = nil, allowUnavailableIndexBlocks: Bool = false) throws -> LegacyPairInspection {
        let content = try inspectOne(url: lsfURL, expectedType: "GTTL")
        let index = try lixURL.map { try inspectOne(url: $0, expectedType: "BIDX", allowUnavailableBlocks: allowUnavailableIndexBlocks) }
        var warnings = content.warnings + (index?.warnings ?? [])
        let matches: Bool?
        if let lsfID = content.identifier, let indexID = index?.identifier,
           lsfID.count == 10, indexID.count == 12 {
            matches = indexID.dropFirst(2).elementsEqual(lsfID)
            if matches == false { warnings.append("Los identificadores bkid de LSF y LIX no coinciden.") }
        } else {
            matches = nil
            if index != nil { warnings.append("No se pudo comparar bkid con el esquema observado de 10/12 bytes.") }
        }
        return LegacyPairInspection(lsf: content.metadata, lix: index?.metadata,
                                    identifiersMatch: matches, warnings: warnings)
    }

    private struct Inspection {
        let metadata: LegacyMetadata
        let identifier: Data?
        let warnings: [String]
    }

    private static let directoryLimit: UInt64 = 16 * 1024 * 1024
    private static let metadataLimit: UInt64 = 16 * 1024

    private static func inspectOne(url: URL, expectedType: String, allowUnavailableBlocks: Bool = false) throws -> Inspection {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        let size = try stream.seekToEnd()
        guard size >= 44 else { throw LegacyReaderError.invalidSignature }
        let header = try read(stream, offset: 0, count: 44, fileSize: size)
        guard ascii(header, 0, 4) == "LSFF" else { throw LegacyReaderError.invalidSignature }
        guard UInt64(u32(header, 4)) + 8 == size else { throw LegacyReaderError.declaredSizeMismatch }
        let kind = ascii(header, 8, 4)
        guard kind == expectedType else {
            throw LegacyReaderError.wrongResourceType(expected: expectedType, actual: kind)
        }
        guard ascii(header, 36, 4) == "pcr " else { throw LegacyReaderError.invalidDirectory }
        let directorySize = UInt64(u32(header, 40))
        guard directorySize <= directoryLimit else { throw LegacyReaderError.directoryLimitExceeded }
        guard directorySize >= 18, (directorySize - 18) % 18 == 0,
              directorySize <= size - 44 else { throw LegacyReaderError.invalidDirectory }
        let directory = try read(stream, offset: 44, count: directorySize, fileSize: size)
        guard ascii(directory, 0, 4) == "LSFF", ascii(directory, 4, 4) == expectedType else {
            throw LegacyReaderError.invalidDirectory
        }
        var blocks: [LegacyBlock] = []
        var warnings: [String] = []
        blocks.reserveCapacity((directory.count - 18) / 18)
        for index in stride(from: 18, to: directory.count, by: 18) {
            let tag = ascii(directory, index, 4)
            let offset = UInt64(u32(directory, index + 12))
            let length = UInt64(u32(directory, index + 8))
            if offset > size || length > size - min(offset, size) {
                guard allowUnavailableBlocks else { throw LegacyReaderError.invalidRange(tag: tag) }
                // Modern books can retain legacy search-directory entries whose
                // payload has moved to a separate native index member. Do not
                // expose those unavailable entries as readable blocks.
                warnings.append("Índice separado pendiente: \(tag).")
                continue
            }
            blocks.append(LegacyBlock(tag: tag, offset: offset, length: length,
                                      declaredChildren: u16(directory, index + 16),
                                      flags: u32(directory, index + 4)))
        }
        func publicBlock(_ tag: String) throws -> Data? {
            let matches = blocks.filter { $0.tag == tag }
            if matches.count > 1 { warnings.append("Se encontraron varios bloques \(tag); se usa el primero.") }
            guard let block = matches.first else { return nil }
            guard block.length <= metadataLimit else { throw LegacyReaderError.readLimitExceeded }
            guard block.offset >= 8 else { throw LegacyReaderError.invalidMetadata(tag: tag) }
            let blockHeader = try read(stream, offset: block.offset - 8, count: 8, fileSize: size)
            guard ascii(blockHeader, 0, 4) == tag,
                  UInt64(u32(blockHeader, 4)) == block.length else {
                throw LegacyReaderError.invalidMetadata(tag: tag)
            }
            return try read(stream, offset: block.offset, count: block.length, fileSize: size)
        }
        let identifier = try publicBlock("bkid")
        var title: String?
        var marc: [MARCField] = []
        if expectedType == "GTTL" {
            if let display = try publicBlock("gtdt") {
                title = displayTitle(display)
                if title == nil { warnings.append("No se reconoció el título público del bloque gtdt.") }
            } else { warnings.append("El recurso no contiene un bloque gtdt público.") }
            if let bibliographic = try publicBlock("marc") {
                if let parsed = parseMARC(bibliographic) { marc = parsed }
                else { warnings.append("La ficha MARC no tiene la estructura validada; sus campos no se usan.") }
            } else { warnings.append("El recurso no contiene una ficha MARC.") }
        }
        let metadata = LegacyMetadata(title: title, marcTitle: joined(marc, tag: "245", codes: "ab"),
                                      uniformTitle: joined(marc, tag: "130", codes: "a"),
                                      author: joined(marc, tag: "100", codes: "acd"),
                                      responsibility: joined(marc, tag: "245", codes: "c"),
                                      declaredLanguages: values(marc, tag: "041", codes: "a"),
                                      publisher: joined(marc, tag: "260", codes: "b"),
                                      publication: joined(marc, tag: "260", codes: "abc"),
                                      bkidHex: identifier.map(hex), blocks: blocks)
        return Inspection(metadata: metadata, identifier: identifier, warnings: warnings)
    }

    private static func read(_ stream: FileHandle, offset: UInt64, count: UInt64, fileSize: UInt64) throws -> Data {
        guard offset <= fileSize, count <= fileSize - offset else { throw LegacyReaderError.invalidRange(tag: "lectura") }
        guard count <= directoryLimit, count <= UInt64(Int.max) else { throw LegacyReaderError.readLimitExceeded }
        try stream.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(Int(count))
        while result.count < Int(count) {
            let remaining = Int(count) - result.count
            guard let part = try stream.read(upToCount: remaining), !part.isEmpty else {
                throw LegacyReaderError.invalidRange(tag: "lectura incompleta")
            }
            result.append(part)
        }
        return result
    }

    private static func displayTitle(_ data: Data) -> String? {
        guard data.count >= 74 else { return nil }
        let length = Int(u16(data, 72))
        guard length > 0, length <= 1024, length <= data.count - 74 else { return nil }
        return nonEmpty(decodeCP1252(data.subdata(in: 74..<(74 + length)))
            .unicodeScalars.filter { $0.value >= 32 }.map(String.init).joined())
    }

    private struct MARCField {
        let tag: String
        let subfields: [(code: Character, value: String)]
    }

    private static func parseMARC(_ data: Data) -> [MARCField]? {
        guard data.count >= 25 else { return nil }
        // A two-byte length prefix was observed, but validate candidates rather
        // than depending on a prefix whose schema has not been established.
        for start in 0...min(16, data.count - 25) {
            let raw = data.subdata(in: start..<data.count)
            guard let recordSize = decimal(raw, 0, 5), let base = decimal(raw, 12, 5),
                  recordSize <= raw.count, base > 24, base < recordSize,
                  (base - 25) % 12 == 0, raw[base - 1] == 0x1e,
                  raw[recordSize - 1] == 0x1d else { continue }
            var fields: [MARCField] = []
            var valid = true
            for index in stride(from: 24, to: base - 1, by: 12) {
                guard let length = decimal(raw, index + 3, 4),
                      let position = decimal(raw, index + 7, 5), length > 0,
                      position <= recordSize - base,
                      length <= recordSize - base - position else { valid = false; break }
                let begin = base + position
                guard raw[begin + length - 1] == 0x1e else { valid = false; break }
                let tag = ascii(raw, index, 3)
                guard tag.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { valid = false; break }
                let field = raw.subdata(in: begin..<(begin + length - 1))
                if tag.hasPrefix("00") { continue }
                guard field.count >= 2 else { valid = false; break }
                let text = decodeCP1252(field.dropFirst(2))
                let subfields: [(Character, String)] = text.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                    .dropFirst().compactMap { part in
                        guard let code = part.first else { return nil }
                        return (code, String(part.dropFirst()))
                    }
                fields.append(MARCField(tag: tag, subfields: subfields))
            }
            if valid { return fields }
        }
        return nil
    }

    private static func values(_ fields: [MARCField], tag: String, codes: String) -> [String] {
        fields.filter { $0.tag == tag }.flatMap(\.subfields)
            .filter { codes.contains($0.code) }.compactMap { nonEmpty($0.value) }
    }

    private static func joined(_ fields: [MARCField], tag: String, codes: String) -> String? {
        nonEmpty(values(fields, tag: tag, codes: codes).joined(separator: " | "))
    }

    private static func nonEmpty(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func decimal(_ data: Data, _ start: Int, _ length: Int) -> Int? {
        guard start >= 0, length > 0, start <= data.count, length <= data.count - start else { return nil }
        var result = 0
        for byte in data[start..<(start + length)] {
            guard byte >= 48, byte <= 57 else { return nil }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }

    private static func ascii(_ data: Data, _ start: Int, _ length: Int) -> String {
        String(decoding: data[start..<(start + length)], as: UTF8.self)
    }

    private static func u16(_ data: Data, _ start: Int) -> UInt16 {
        UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    private static func u32(_ data: Data, _ start: Int) -> UInt32 {
        UInt32(data[start]) | UInt32(data[start + 1]) << 8 | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
    }

    /// These old public metadata use ANSI bytes. Preserve Windows-1252 accents
    /// without requiring an external encoding package or modifying book text.
    static func decodeCP1252<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let special: [UInt8: UInt32] = [0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192,
                                      0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020,
                                      0x87: 0x2021, 0x88: 0x02c6, 0x89: 0x2030,
                                      0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152,
                                      0x8e: 0x017d, 0x91: 0x2018, 0x92: 0x2019,
                                      0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022,
                                      0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc,
                                      0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a,
                                      0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178]
        return String(String.UnicodeScalarView(bytes.map { UnicodeScalar(special[$0] ?? UInt32($0))! }))
    }
}
