import Foundation

public enum LegacyTypographyError: Error, LocalizedError, Sendable, Equatable {
    case missingTable, invalidTable, unsupportedVersion, unsupportedAttachment, limitExceeded
    public var errorDescription: String? {
        switch self {
        case .missingTable: "El recurso no contiene una tabla de estilos compatible."
        case .invalidTable: "La tabla de estilos no coincide con sus campos y límites."
        case .unsupportedVersion: "Esta versión de estilos todavía no se interpreta."
        case .unsupportedAttachment: "La tabla contiene un estilo con contenido adjunto todavía no compatible."
        case .limitExceeded: "La tabla de estilos supera los límites de lectura."
        }
    }
}

public struct LegacyFontGroup: Codable, Equatable, Sendable {
    public let name: String
    public let family: String
}
public struct LegacyFontDescription: Codable, Equatable, Sendable {
    /// Five packed LOGFONT fields; v1/v2 read u16, v3/v4 read u32. Preserve
    /// their representation instead of treating unknown sentinel values as sizes.
    public let values: [UInt32]
    public let attributes: [UInt8]
    public let family: String
    public let rawFamily: Data
    public var height: UInt32 { values[0] }
    public var weight: UInt32 { values[4] }
    public var italic: Bool { attributes[0] != 0 }
    public var underline: Bool { attributes[1] != 0 }
    public var strikeout: Bool { attributes[2] != 0 }
}
public struct LegacyCharacterStyle: Codable, Equatable, Sendable {
    public let id: UInt16
    public let version: UInt16
    public let flags: UInt32
    public let color: UInt32
    public let backgroundColor: UInt32?
    public let locale: UInt16
    public let sourceField: UInt16
    public let extraField: UInt16?
    public let extraValue: UInt32?
    public let font: LegacyFontDescription
    public let alternateFont: LegacyFontDescription?
    /// Masks are confirmed by the original HTML writer, separately from the
    /// packed font's bold/italic/underline fields.
    public var isSuperscript: Bool { flags & 1 != 0 }
    public var isSubscript: Bool { flags & 2 != 0 }
    public var smallCaps: Bool { flags & 0x20 != 0 }
    public var capitalizeWords: Bool { flags & 0x10 != 0 }
}
public struct LegacyParagraphBorder: Codable, Equatable, Sendable {
    public let version: UInt16
    public let kind: UInt16
    public let width: Int16
    public let padding: Int16
    public let color: UInt32
}
public struct LegacyTabStop: Codable, Equatable, Sendable {
    public let version: UInt16
    public let kind: UInt16
    public let position: Int16
}
public enum LegacyTextAlignment: String, Codable, Sendable { case left, right, center, justified }
public struct LegacyParagraphStyle: Codable, Equatable, Sendable {
    public let version: UInt16
    public let borders: [LegacyParagraphBorder]
    public let firstValue: UInt32
    public let secondValue: UInt32
    public let fields: [UInt16]
    public let name: String
    public let extraLineHeight: Int16?
    public let flags: UInt16
    public let tabStops: [LegacyTabStop]
    public var id: UInt16 { fields[0] }
    public var relatedStyleID: UInt16 { fields[1] }
    public var headIndent: Int16 { Int16(bitPattern: fields[2]) }
    public var tailIndent: Int16 { Int16(bitPattern: fields[3]) }
    public var firstLineIndent: Int16 { Int16(bitPattern: fields[4]) }
    public var spaceBefore: Int16 { Int16(bitPattern: fields[5]) }
    public var spaceAfter: Int16 { Int16(bitPattern: fields[6]) }
    public var sourceLineField: Int16 { Int16(bitPattern: fields[7]) }
    public var characterStyleID: UInt16 { fields[8] }
    public var rightToLeft: Bool { flags & 2 != 0 }
    public var alignment: LegacyTextAlignment? {
        if flags & 4 != 0 { return .left }
        if flags & 8 != 0 { return .right }
        if flags & 0x10 != 0 { return .center }
        if flags & 0x20 != 0 { return .justified }
        return nil
    }
}
public struct LegacyTypography: Codable, Equatable, Sendable {
    public let version: UInt16
    public let fontGroupVersion: UInt16
    public let fontGroups: [LegacyFontGroup]
    public let characterStyles: [LegacyCharacterStyle]
    public let paragraphStyles: [LegacyParagraphStyle]
    /// An optional final typed-group map remains opaque; no text or styles are
    /// discarded from the source. RVR60 has no tail in the checked fixture.
    public let opaqueTail: Data
    public func characterStyle(_ id: UInt16) -> LegacyCharacterStyle? {
        Int(id) < characterStyles.count ? characterStyles[Int(id)] : nil
    }
    public func paragraphStyle(_ id: UInt32) -> LegacyParagraphStyle? {
        guard id <= UInt16.max else { return nil }
        let matches = paragraphStyles.filter { $0.id == UInt16(id) }
        // Named prototype records can share a numeric field. Keep all of them;
        // don't choose a rendering definition until its precedence is proved.
        return matches.count == 1 ? matches[0] : nil
    }
    public func family(for font: LegacyFontDescription) -> String {
        guard font.family.hasPrefix("*") else { return font.family }
        return fontGroups.first { $0.name == String(font.family.dropFirst()) }?.family ?? font.family
    }
}

public enum LegacyTypographyReader {
    public static func inspect(lsfURL: URL) throws -> LegacyTypography {
        let metadata = try LegacyResourceReader.inspect(lsfURL: lsfURL).lsf
        let tables = metadata.blocks.filter { $0.tag == "ttbl" }
        guard tables.count == 1, let table = tables.first else { throw LegacyTypographyError.missingTable }
        guard table.offset >= 8, table.length <= 16 * 1024 * 1024 else { throw LegacyTypographyError.limitExceeded }
        let stream = try FileHandle(forReadingFrom: lsfURL); defer { try? stream.close() }
        try stream.seek(toOffset: table.offset - 8)
        guard let data = try stream.read(upToCount: Int(table.length + 8)), data.count == table.length + 8,
              String(decoding: data.prefix(4), as: UTF8.self) == "ttbl" else { throw LegacyTypographyError.invalidTable }
        let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[4 + $1]) << ($1 * 8) }
        guard length == table.length else { throw LegacyTypographyError.invalidTable }
        return try decode(Data(data.dropFirst(8)))
    }
    public static func decode(_ data: Data) throws -> LegacyTypography {
        guard data.count <= 16 * 1024 * 1024 else { throw LegacyTypographyError.limitExceeded }
        var reader = TypographyDecoder(data: data)
        return try reader.decode()
    }
}

private struct TypographyDecoder {
    let data: Data
    var cursor = 0
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, cursor <= data.count, count <= data.count - cursor else { throw LegacyTypographyError.invalidTable }
        let part = data.subdata(in: cursor..<(cursor + count)); cursor += count; return part
    }
    mutating func word() throws -> UInt16 {
        let value = try take(2); return UInt16(value[0]) | UInt16(value[1]) << 8
    }
    mutating func integer() throws -> UInt32 {
        let value = try take(4); return (0..<4).reduce(UInt32(0)) { $0 | UInt32(value[$1]) << ($1 * 8) }
    }
    mutating func count() throws -> Int {
        let count = Int(try word()); guard count <= 4_096 else { throw LegacyTypographyError.limitExceeded }; return count
    }
    func narrow(_ bytes: Data) throws -> String {
        guard let value = String(data: bytes, encoding: .windowsCP1252) else { throw LegacyTypographyError.invalidTable }
        return value
    }
    mutating func text() throws -> String { let length = try count(); return try narrow(take(length)) }
    mutating func font(_ version: UInt16) throws -> LegacyFontDescription {
        var values: [UInt32] = []
        for _ in 0..<5 { values.append(version < 3 ? UInt32(try word()) : try integer()) }
        let attributes = Array(try take(8)), rawFamily = try take(32)
        let end = rawFamily.firstIndex(of: 0) ?? rawFamily.endIndex
        return LegacyFontDescription(values: values, attributes: attributes, family: try narrow(Data(rawFamily[..<end])), rawFamily: rawFamily)
    }
    mutating func decode() throws -> LegacyTypography {
        let version = try word(), fontVersion = try word()
        guard version == 1, fontVersion == 1 else { throw LegacyTypographyError.unsupportedVersion }
        var groups: [LegacyFontGroup] = []
        for _ in 0..<(try count()) { groups.append(.init(name: try text(), family: try text())) }
        var characters: [LegacyCharacterStyle] = []
        for id in 0..<(try count()) {
            try Task.checkCancellation()
            let version = try word(); guard (1...4).contains(version) else { throw LegacyTypographyError.unsupportedVersion }
            let flags = try integer(), color = try integer(), background = version >= 2 ? try integer() : nil
            let locale = try word(), field = try word(), extraField = version >= 4 ? try word() : nil
            let extraValue = version >= 4 ? try integer() : nil, firstFont = try font(version), alternate = try word()
            guard alternate <= 1 else { throw LegacyTypographyError.invalidTable }
            characters.append(.init(id: UInt16(id), version: version, flags: flags, color: color, backgroundColor: background,
                locale: locale, sourceField: field, extraField: extraField, extraValue: extraValue, font: firstFont,
                alternateFont: alternate == 1 ? try font(version) : nil))
        }
        var paragraphs: [LegacyParagraphStyle] = []
        for _ in 0..<(try count()) {
            try Task.checkCancellation()
            let version = try word(); guard (1...3).contains(version) else { throw LegacyTypographyError.unsupportedVersion }
            var borders: [LegacyParagraphBorder] = []
            for _ in 0..<4 {
                let version = try word(); guard version == 1 else { throw LegacyTypographyError.unsupportedVersion }
                borders.append(.init(version: version, kind: try word(), width: Int16(bitPattern: try word()),
                    padding: Int16(bitPattern: try word()), color: try integer()))
            }
            let first = try integer(), second = try integer()
            var fields: [UInt16] = []; for _ in 0..<10 { fields.append(try word()) }
            guard fields[9] <= 4_096 else { throw LegacyTypographyError.limitExceeded }
            let name = try narrow(take(Int(fields[9]))), extra = version >= 3 ? Int16(bitPattern: try word()) : nil
            let flags = try word(); var tabs: [LegacyTabStop] = []
            for _ in 0..<(try count()) {
                let version = try word(); guard version == 1 else { throw LegacyTypographyError.unsupportedVersion }
                tabs.append(.init(version: version, kind: try word(), position: Int16(bitPattern: try word())))
            }
            guard try word() == 0 else { throw LegacyTypographyError.unsupportedAttachment }
            guard fields[8] == UInt16.max || Int(fields[8]) < characters.count else { throw LegacyTypographyError.invalidTable }
            paragraphs.append(.init(version: version, borders: borders, firstValue: first, secondValue: second, fields: fields,
                name: name, extraLineHeight: extra, flags: flags, tabStops: tabs))
        }
        return LegacyTypography(version: version, fontGroupVersion: fontVersion, fontGroups: groups,
            characterStyles: characters, paragraphStyles: paragraphs, opaqueTail: try take(data.count - cursor))
    }
}
