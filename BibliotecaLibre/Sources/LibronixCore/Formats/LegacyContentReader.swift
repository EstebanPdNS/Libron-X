import Foundation
#if canImport(CLibronxCompression)
import CLibronxCompression
#endif

/// Physical sections retain file order; they are distinct from named references.
public struct LegacySectionDescriptor: Sendable, Codable, Equatable, Identifiable {
    public let ordinal: Int
    public let headerOffset: UInt64
    public let payloadOffset: UInt64
    public let storedLength: UInt32
    public let decodedLength: UInt32
    public let mode: UInt16
    /// Mode 1, codec zero is the observed PKWARE DCL variant.
    public let codecWord: UInt16?
    public var id: Int { ordinal }
    public var isUncompressed: Bool { mode == 0 }
}

public struct LegacySectionIndex: Sendable, Codable, Equatable {
    public let tartOffset: UInt64
    public let tartLength: UInt64
    public let sections: [LegacySectionDescriptor]
}

/// Stored text is retained exactly. Logical control prefixes are distinct from
/// encoding flags and style IDs; no bold/italic/link semantics are guessed.
public struct LegacyTextRun: Sendable, Codable, Equatable {
    public let text: String
    public let controlToken: UInt16
    /// Compatibility name for the preserved u16 after the token. Native byte
    /// evidence identifies this field as CRun flags, not a style identifier.
    public let styleValue: UInt32
    public let localeIdentifier: UInt16
    /// LString encoding byte. Zero is a compatibility placeholder when a
    /// normal empty run has no serialized encoding byte.
    public let flags: UInt8
    public let trailingControl: UInt16
    public let attribute: String?
    public let characterOffset: Int
    /// There is no direct byte mapping into compressed data for decoded runs.
    public let fileOffset: UInt64?
    public let decodedOffset: UInt64
    public var extendedAttributes: LegacyRunAttributes? = nil
    public var extraValue: UInt32? = nil
    public var sourceRunFlags: UInt16 { UInt16(truncatingIfNeeded: styleValue) }
    public var styleIdentifier: UInt16 { trailingControl }
    /// Compatibility accessor. The serialized byte is a high Unicode page,
    /// not a bitmap; 0xf0 selects full UTF-16 storage.
    public var textEncodingFlags: UInt8 { flags }
    public var serializedTextEncodingByte: UInt8? { controlToken != 0x12 && text.isEmpty ? nil : flags }
    public var textEncodingPage: UInt8? {
        guard let encoding = serializedTextEncodingByte else { return nil }
        return encoding == 0xf0 ? nil : encoding
    }
    public var isStoredUTF16: Bool { serializedTextEncodingByte == 0xf0 }
    public var hasLeadingSoftBreak: Bool { sourceRunFlags & 0x20 != 0 }
    public var leadingControlText: String { hasLeadingSoftBreak ? "\u{2028}" : "" }
    public var logicalText: String { leadingControlText + text }
    public var logicalCharacterCount: Int { text.utf16.count + (hasLeadingSoftBreak ? 1 : 0) }
    public var storedTextCharacterOffset: Int { characterOffset + (hasLeadingSoftBreak ? 1 : 0) }
}

/// The shared 0xf00d header owns a bounded inner stream. Attribute strings,
/// numbers, reserved flag bits and its unused tail are retained independently.
public struct LegacyRunAttributes: Sendable, Codable, Equatable {
    public let flags: UInt16
    public let rawData: Data
    public let strings: [Data]
    public let values: [UInt32]
    public let unparsedTail: Data
}

public struct LegacyReferenceAnchor: Sendable, Codable, Equatable {
    /// Supported textual data types preserve their source reference string.
    /// A structured type-8 reference has no serialized textual reference.
    public let reference: String?
    public let flags: UInt16
    public let dataTypeCode: UInt16
    public let characterOffset: Int
    public let decodedOffset: UInt64
    public let structuredReference: LegacyStructuredReference?
    /// 0x52 stores a 32-bit byte count followed by a terminated reference.
    /// Its second word is a format flag field, not the 0x51 data type.
    public var sourceToken: UInt16 { referenceFormatFlags == nil ? 0x51 : 0x52 }
    public var referenceFormatFlags: UInt16? = nil
    public var serializedReference: Data? = nil

    public init(reference: String?, flags: UInt16, dataTypeCode: UInt16, characterOffset: Int,
                decodedOffset: UInt64, structuredReference: LegacyStructuredReference? = nil,
                referenceFormatFlags: UInt16? = nil, serializedReference: Data? = nil) {
        self.reference = reference; self.flags = flags; self.dataTypeCode = dataTypeCode
        self.characterOffset = characterOffset; self.decodedOffset = decodedOffset
        self.structuredReference = structuredReference
        self.referenceFormatFlags = referenceFormatFlags
        self.serializedReference = serializedReference
    }
}

/// Type-8 identifiers are byte strings, without an LString page or language
/// selector. Numeric components retain their exact 32-bit source patterns.
public struct LegacyStructuredReference: Sendable, Codable, Equatable {
    public let schemeBytes: Data
    public let componentBits: [UInt32]

    public init(schemeBytes: Data, componentBits: [UInt32]) {
        self.schemeBytes = schemeBytes; self.componentBits = componentBits
    }

    /// The separately verified Page schema uses alias P and one dimension.
    /// This recognizes that identity, without resolving a navigation target.
    public var knownScheme: LegacyStructuredReferenceScheme? {
        schemeBytes == Data([0x50]) && componentBits.count == 1 ? .page : nil
    }
}

public enum LegacyStructuredReferenceScheme: String, Sendable, Codable, Equatable {
    case page = "Page"
}

public struct LegacyParagraph: Sendable, Codable, Equatable {
    public let text: String
    public let styleIdentifier: UInt32
    public let flags: UInt16
    public let characterOffset: Int
    public let declaredCharacterCount: UInt32
    public let kind: LegacyParagraphKind
    public let version: UInt16
    public let declaredRunCount: UInt16
    public let fieldAfterFlags: UInt16
    public let fieldAfterCount: UInt16
    public let decodedOffset: UInt64
    public let label: LegacyParagraphLabel?
    public let table: LegacyTable?
    public let children: [LegacyParagraph]
    public let containerVersion: UInt16?
    public var logicalCharacterCount: Int { text.utf16.count + (kind == .miniList ? 0 : 1) }
}

public enum LegacyParagraphKind: String, Sendable, Codable { case text, table, miniList }

/// A list/header label has its own source bytes. It does not occupy positions
/// in the paragraph body and must not shift body anchors or search ranges.
public struct LegacyParagraphLabel: Sendable, Codable, Equatable {
    public let token: UInt16
    public let text: String
    public let sourceBytes: Data
    public let decodedOffset: UInt64
    public let fileOffset: UInt64?
    public let firstField: UInt16
    public let secondField: UInt16
}

public struct LegacyTableMeasurement: Sendable, Codable, Equatable {
    public let version: UInt16
    public let flags: UInt16
    public let firstValue: Int16
    public let secondValue: Int16
    public let value: UInt32
}

public struct LegacyTable: Sendable, Codable, Equatable {
    public let version: UInt16
    public let sourceField: UInt16
    public let overwrittenColumnField: UInt16
    public let columnCount: UInt16
    public let rows: [LegacyTableRow]
    public let characterOffset: Int
    public let characterCount: Int
    public let decodedOffset: UInt64
}

public struct LegacyTableRow: Sendable, Codable, Equatable {
    public let version: UInt16
    public let flags: UInt16
    public let fields: [Int16]
    public let measurements: [LegacyTableMeasurement]
    public let cells: [LegacyTableCell]
    public let characterOffset: Int
    public let characterCount: Int
    public let decodedOffset: UInt64
}

public struct LegacyTableCell: Sendable, Codable, Equatable {
    public let version: UInt16
    public let versionFlags: UInt16
    public let sourceFlags: UInt16
    public let firstField: Int16
    public let secondField: Int16
    public let extendedField: Int16?
    public let firstValue: UInt32
    public let secondValue: UInt32
    public let measurements: [LegacyTableMeasurement]
    public let content: LegacyParagraph
    public let characterOffset: Int
    public let characterCount: Int
    public let decodedOffset: UInt64
}

public enum LegacyInlineMarkerKind: String, Sendable, Codable {
    case tab, special
}

public struct LegacyInlineMarker: Sendable, Codable, Equatable {
    public let token: UInt16
    public let value: UInt32
    public let sourceRunFlags: UInt16
    public let characterOffset: Int
    public let decodedOffset: UInt64
    public let fileOffset: UInt64?
    public let rawHeaderHex: String
    public let characterWidth: Int
    /// The 0x21 CTabRun has one unit. A 0x71 CSpecialRun has value & 1
    /// stored units plus the common implicit soft-break unit. Retain the flags
    /// and value separately from this logical text projection and final layout.
    public var kind: LegacyInlineMarkerKind { token == 0x71 ? .special : .tab }
    public var hasLeadingSoftBreak: Bool { sourceRunFlags & 0x20 != 0 }
    public var replacementText: String { kind == .tab ? "\t" : (value & 1 == 0 ? "" : " ") }
    public var logicalText: String { (hasLeadingSoftBreak ? "\u{2028}" : "") + replacementText }
}

public struct LegacyGraphicRun: Sendable, Codable, Equatable {
    public let sourceRunFlags: UInt16
    public let attribute: String?
    public let reference: String
    public let characterOffset: Int
    public let decodedOffset: UInt64
    public let fileOffset: UInt64?
    public let rawHeaderHex: String
    public var extendedAttributes: LegacyRunAttributes? = nil
    public var embeddedData: Data? = nil
    public var embeddedFormat: String? = nil
    public var intrinsicWidth: Int? = nil
    public var intrinsicHeight: Int? = nil
    public var hasLeadingSoftBreak: Bool { sourceRunFlags & 0x20 != 0 }
    public var characterWidth: Int { 1 + (hasLeadingSoftBreak ? 1 : 0) }
    public var objectCharacterOffset: Int { characterOffset + (hasLeadingSoftBreak ? 1 : 0) }
    public var logicalText: String { (hasLeadingSoftBreak ? "\u{2028}" : "") + "\u{fffc}" }
    /// Prefix options remain source metadata. Only a resource-local !name is
    /// resolved; no path or URL supplied by a book is opened as an external file.
    public var assetName: String? {
        var rest = reference[...]
        while rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            rest = rest[rest.index(after: close)...]
        }
        guard rest.first == "!", rest.count > 1 else { return nil }
        return String(rest.dropFirst())
    }
}

/// Neutral identities follow native flags and stream order, without assigning
/// heading/body display roles. All content coordinates in a frame are local.
public struct LegacyParagraphDocument: Sendable, Codable, Equatable {
    public let sourceFlag: UInt32
    public let version: UInt16
    public let opaqueWord: UInt16
    public let declaredCharacterExtentBits: UInt32
    public let declaredParagraphCount: UInt16
    public let decodedStart: UInt64
    public let decodedEnd: UInt64
    public let fileOffset: UInt64?
    public let projectedCharacterBase: Int
    /// Initial direct native channel: bit-1 document follows bit-2's raw extent.
    /// A raw 0xffffffff first extent remains -1, rather than being clamped.
    public let nativeDirectCharacterBaseBits: UInt32
    public let plainText: String
    public let paragraphs: [LegacyParagraph]
    public let runs: [LegacyTextRun]
    public let anchors: [LegacyReferenceAnchor]
    public let markers: [LegacyInlineMarker]
    public let graphics: [LegacyGraphicRun]
    public var interlinears: [LegacyInterlinearRun]? = nil
    public var projectedCharacterCount: Int { plainText.utf16.count }
    public var nativeDirectCharacterBase: Int32 { Int32(bitPattern: nativeDirectCharacterBaseBits) }
    public var hasEmptyExtentSentinel: Bool { declaredParagraphCount == 0 && declaredCharacterExtentBits == UInt32.max }
    /// Exact initial 32-bit arithmetic; this does not apply native filtering or
    /// the alternate paragraph virtual coordinate conversion.
    public func initialDirectArticlePosition(localPosition: Int32) -> Int32 {
        nativeDirectCharacterBase &+ localPosition
    }
    public func initialDirectLocalPosition(articlePosition: Int32) -> Int32 {
        articlePosition &- nativeDirectCharacterBase
    }
}

public struct LegacyDirectDocumentPosition: Sendable, Codable, Equatable {
    public let sourceFlag: UInt32
    public let localPosition: Int32
}

public struct LegacySectionHeader: Sendable, Codable, Equatable {
    public let flags: UInt32
    public let rangeIdentifier: UInt32?
    public let rangeEntries: [LegacySectionRangeEntry]
    public let referencePrefix: Data?
}

/// Neutral names preserve the range payload without assuming that its two
/// native coordinates are a flat view-text range.
public struct LegacySectionRangeEntry: Sendable, Codable, Equatable {
    public let name: Data
    public let firstPosition: UInt32
    public let secondPosition: UInt32
}

public struct LegacySectionContent: Sendable, Codable, Equatable {
    public var richTextRTF: Data? = nil
    public static func imported(text: String, ordinal: Int, anchors: [LegacyReferenceAnchor], rtf: Data?) -> Self {
        var content = Self(descriptor: .init(ordinal: ordinal, headerOffset: 0, payloadOffset: 0, storedLength: 0,
            decodedLength: UInt32(text.utf16.count), mode: 0, codecWord: nil), plainText: text, runs: [],
            expectedCharacterCount: UInt32(text.utf16.count), recognizedFormat: "libron-import-v1", paragraphs: [],
            anchors: anchors, markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
        content.richTextRTF = rtf
        return content
    }
    public let descriptor: LegacySectionDescriptor
    public let plainText: String
    public let runs: [LegacyTextRun]
    public let expectedCharacterCount: UInt32
    public let recognizedFormat: String
    public let paragraphs: [LegacyParagraph]
    public let anchors: [LegacyReferenceAnchor]
    public let markers: [LegacyInlineMarker]
    public let graphics: [LegacyGraphicRun]
    public var tables: [LegacyTable] { paragraphs.compactMap(\.table) }
    public let warnings: [String]
    /// Optional for backward decoding of JSON captured before frame metadata.
    /// Current reader output retains all source documents independently.
    public let paragraphDocuments: [LegacyParagraphDocument]?
    public var storedHeader: LegacySectionHeader? = nil
    public var interlinears: [LegacyInterlinearRun]? = nil
    public var documentSourceFlags: UInt32? { storedHeader?.flags ?? paragraphDocuments?.reduce(0) { $0 | $1.sourceFlag } }
    /// Flat view positions use complete text, with no fabricated boundary unit.
    /// The declared native extent can differ for an empty-frame sentinel.
    public var hasCompatibleFlatTextProjection: Bool { UInt64(plainText.utf16.count) == UInt64(expectedCharacterCount) }
    /// Bounded construction-time direct router (option bit 1). This exposes
    /// frame coordinates without resolving a locator, applying native filtering
    /// or assuming the alternate virtual conversion is UTF-16 identity.
    public func initialDirectDocumentPosition(forArticlePosition position: Int32) -> LegacyDirectDocumentPosition? {
        guard position >= 0, UInt32(position) <= expectedCharacterCount, let documents = paragraphDocuments else { return nil }
        let first = documents.first { $0.sourceFlag == 2 }
        let selected: LegacyParagraphDocument?
        if let first, position < Int32(bitPattern: first.declaredCharacterExtentBits) { selected = first }
        else { selected = documents.first { $0.sourceFlag == 1 } }
        guard let selected else { return nil }
        let local = selected.initialDirectLocalPosition(articlePosition: position)
        guard local >= 0, Int(local) <= selected.projectedCharacterCount else { return nil }
        return LegacyDirectDocumentPosition(sourceFlag: selected.sourceFlag, localPosition: local)
    }
}

public enum LegacyContentError: Error, Sendable, Equatable, LocalizedError {
    case missingSectionContainer
    case invalidSectionContainer
    case unsupportedMode(UInt16)
    case compressedSectionUnsupported(codecWord: UInt16)
    case sectionNotFound(Int)
    case invalidRange(offset: UInt64)
    case contentLimitExceeded
    case unsupportedRunStructure(offset: UInt64)
    case unsupportedLocale(UInt16)
    case characterCountMismatch
    case declaredExtentMismatch(scope: String, offset: UInt64, expected: UInt32, actual: UInt32)
    case decompressionFailed(Int32)
    case decompressedLengthMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .missingSectionContainer: "El recurso no declara un bloque tart."
        case .invalidSectionContainer: "El contenedor tart no coincide con su directorio."
        case let .unsupportedMode(mode): "El modo de sección \(mode) todavía no se interpreta."
        case let .compressedSectionUnsupported(codec): "Esta sección usa compresión (codec observado \(codec)); su lector todavía no está implementado."
        case let .sectionNotFound(index): "La sección física \(index) no existe."
        case let .invalidRange(offset): "Rango de sección inválido en el offset \(offset)."
        case .contentLimitExceeded: "La sección supera el límite seguro de este lector inicial."
        case let .unsupportedRunStructure(offset): "La estructura de texto en el offset \(offset) no pertenece al subconjunto validado."
        case let .unsupportedLocale(locale): "La codificación de la lengua \(locale) aún no se interpreta."
        case .characterCountMismatch: "Los caracteres y límites de la sección no coinciden con sus campos declarados."
        case let .declaredExtentMismatch(scope, offset, expected, actual):
            "El \(scope) en el offset \(offset) declara \(expected) unidades; se leyeron \(actual)."
        case let .decompressionFailed(status): "La descompresión PKWARE DCL falló con el código \(status)."
        case let .decompressedLengthMismatch(expected, actual): "La sección declara \(expected) bytes decodificados y el codec produjo \(actual)."
        }
    }
}

public enum LegacyContentReader {
    /// Enumerates framing only. No book text is read by this operation.
    /// The two framing variants reach the exact end in all 57 local LSF files.
    public static func inspectSections(lsfURL: URL) throws -> LegacySectionIndex {
        let metadata = try LegacyResourceReader.inspect(lsfURL: lsfURL).lsf
        let containers = metadata.blocks.filter { $0.tag == "tart" }
        guard let block = containers.first else { throw LegacyContentError.missingSectionContainer }
        guard containers.count == 1, block.offset >= 8 else { throw LegacyContentError.invalidSectionContainer }
        let stream = try FileHandle(forReadingFrom: lsfURL)
        defer { try? stream.close() }
        let fileSize = try stream.seekToEnd()
        let header = try read(stream, offset: block.offset - 8, count: 8, end: fileSize)
        guard String(decoding: header.prefix(4), as: UTF8.self) == "tart",
              UInt64(u32(header, 4)) == block.length else { throw LegacyContentError.invalidSectionContainer }
        let end = block.offset + block.length
        var cursor = block.offset
        var sections: [LegacySectionDescriptor] = []
        while cursor < end {
            if sections.count.isMultiple(of: 256) { try Task.checkCancellation() }
            guard sections.count < 500_000 else { throw LegacyContentError.contentLimitExceeded }
            let first = try read(stream, offset: cursor, count: 6, end: end)
            let mode = u16(first, 0)
            let headerSize: UInt64
            let storedLength: UInt32
            let decodedLength: UInt32
            let codecWord: UInt16?
            switch mode {
            case 0:
                headerSize = 6
                storedLength = u32(first, 2)
                decodedLength = storedLength
                codecWord = nil
            case 1:
                let full = try read(stream, offset: cursor, count: 12, end: end)
                headerSize = 12
                codecWord = u16(full, 2)
                decodedLength = u32(full, 4)
                storedLength = u32(full, 8)
            default: throw LegacyContentError.unsupportedMode(mode)
            }
            let payload = cursor + headerSize
            guard storedLength > 0, payload <= end,
                  UInt64(storedLength) <= end - payload else { throw LegacyContentError.invalidRange(offset: cursor) }
            if mode == 0 {
                guard storedLength >= 4 else { throw LegacyContentError.invalidRange(offset: payload) }
                let inner = try read(stream, offset: payload, count: 4, end: end)
                guard u32(inner, 0) == storedLength else { throw LegacyContentError.invalidSectionContainer }
            }
            sections.append(LegacySectionDescriptor(ordinal: sections.count, headerOffset: cursor,
                                                    payloadOffset: payload, storedLength: storedLength,
                                                    decodedLength: decodedLength, mode: mode, codecWord: codecWord))
            cursor = payload + UInt64(storedLength)
        }
        guard cursor == end else { throw LegacyContentError.invalidSectionContainer }
        return LegacySectionIndex(tartOffset: block.offset, tartLength: block.length, sections: sections)
    }

    /// Reads one section through validated fields, not by searching printable bytes.
    /// Supported: checked paragraphs, Unicode-page/UTF-16 character runs and
    /// anchors; modes 0 and DCL1. Language selectors are preserved metadata,
    /// independent of the LString storage encoding. Unknown structures fail.
    public static func readSection(lsfURL: URL, ordinal: Int) throws -> LegacySectionContent {
        let index = try inspectSections(lsfURL: lsfURL)
        guard ordinal >= 0, ordinal < index.sections.count else { throw LegacyContentError.sectionNotFound(ordinal) }
        let section = index.sections[ordinal]
        return try readSection(lsfURL: lsfURL, descriptor: section, tartEnd: index.tartOffset + index.tartLength)
    }

    /// Internal cached-descriptor path for indexed navigation. Rechecks framing
    /// against the file before reading, rather than trusting cached lengths.
    static func readSection(lsfURL: URL, descriptor section: LegacySectionDescriptor, tartEnd: UInt64) throws -> LegacySectionContent {
        try decodeSimpleLatinRuns(readSectionPayload(lsfURL: lsfURL, descriptor: section, tartEnd: tartEnd), section: section)
    }

    /// Exact decoded bytes for source-format diagnostics, without scanning for
    /// printable text or changing the original resource.
    public static func decodedSectionPayload(lsfURL: URL, ordinal: Int) throws -> Data {
        let index = try inspectSections(lsfURL: lsfURL)
        guard index.sections.indices.contains(ordinal) else { throw LegacyContentError.sectionNotFound(ordinal) }
        return try readSectionPayload(lsfURL: lsfURL, descriptor: index.sections[ordinal], tartEnd: index.tartOffset + index.tartLength)
    }
    private static func readSectionPayload(lsfURL: URL, descriptor section: LegacySectionDescriptor, tartEnd: UInt64) throws -> Data {
        guard section.storedLength > 0, section.storedLength <= 8 * 1024 * 1024,
              section.decodedLength >= 20, section.decodedLength <= 8 * 1024 * 1024 else {
            throw LegacyContentError.contentLimitExceeded
        }
        let stream = try FileHandle(forReadingFrom: lsfURL)
        defer { try? stream.close() }
        let frameHeaderSize: UInt64 = section.mode == 0 ? 6 : 12
        let frame = try read(stream, offset: section.headerOffset, count: frameHeaderSize, end: tartEnd)
        guard u16(frame, 0) == section.mode,
              (section.mode == 0 ? u32(frame, 2) : u32(frame, 8)) == section.storedLength,
              section.payloadOffset == section.headerOffset + frameHeaderSize else {
            throw LegacyContentError.invalidSectionContainer
        }
        if section.mode == 1 {
            guard u16(frame, 2) == section.codecWord, u32(frame, 4) == section.decodedLength else {
                throw LegacyContentError.invalidSectionContainer
            }
        }
        let stored = try read(stream, offset: section.payloadOffset, count: UInt64(section.storedLength),
                               end: tartEnd)
        let payload: Data
        if section.mode == 0 { payload = stored }
        else {
            guard section.codecWord == 0 else {
                throw LegacyContentError.compressedSectionUnsupported(codecWord: section.codecWord ?? 0)
            }
            payload = try decompressDCL(stored, expectedLength: Int(section.decodedLength))
        }
        return payload
    }

    /// The C wrapper uses the attributed upstream blast decoder with bounded I/O.
    static func decompressDCL(_ input: Data, expectedLength: Int) throws -> Data {
        guard expectedLength > 0, expectedLength <= 8 * 1024 * 1024,
              !input.isEmpty, input.count <= 8 * 1024 * 1024 else { throw LegacyContentError.contentLimitExceeded }
        #if canImport(CLibronxCompression)
        var output = Data(count: expectedLength)
        var written = 0
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                libronx_explode(source.bindMemory(to: UInt8.self).baseAddress, source.count,
                               destination.bindMemory(to: UInt8.self).baseAddress, destination.count, &written)
            }
        }
        guard status == 0 else { throw LegacyContentError.decompressionFailed(Int32(status)) }
        guard written == expectedLength else {
            throw LegacyContentError.decompressedLengthMismatch(expected: expectedLength, actual: written)
        }
        return output
        #else
        throw LegacyContentError.compressedSectionUnsupported(codecWord: 0)
        #endif
    }

    /// Field-based document parser. It never searches printable strings or strips
    /// markup. Unknown opcodes/locales and inconsistent lengths fail explicitly.
    static func decodeSimpleLatinRuns(_ data: Data, section: LegacySectionDescriptor) throws -> LegacySectionContent {
        var decoder = LegacyDocumentDecoder(data: data, section: section)
        return try decoder.decode()
    }

    /// LString materialization combines a stored nonzero byte with its high
    /// Unicode page; a zero byte remains U+0000. This is not a Windows code page.
    /// Strict decoding also rejects surrogate pages without a complete pair.
    static func decodeUnicodePage(_ bytes: Data, page: UInt8, offset: UInt64) throws -> String {
        var utf16 = Data(capacity: bytes.count * 2)
        for byte in bytes {
            utf16.append(byte)
            utf16.append(byte == 0 ? 0 : page)
        }
        return try decodeUTF16(utf16, offset: offset)
    }

    /// Unicode runs use exactly textLength UTF-16 units. Invalid surrogate
    /// sequences are rejected instead of silently substituting replacement text.
    static func decodeUTF16(_ bytes: Data, offset: UInt64) throws -> String {
        guard bytes.count % 2 == 0 else { throw LegacyContentError.unsupportedRunStructure(offset: offset) }
        var scalars = String.UnicodeScalarView()
        var cursor = 0
        while cursor < bytes.count {
            let first = u16(bytes, cursor)
            cursor += 2
            let value: UInt32
            if (0xd800...0xdbff).contains(first) {
                guard cursor < bytes.count else { throw LegacyContentError.unsupportedRunStructure(offset: offset) }
                let second = u16(bytes, cursor)
                guard (0xdc00...0xdfff).contains(second) else { throw LegacyContentError.unsupportedRunStructure(offset: offset) }
                cursor += 2
                value = 0x10000 + (UInt32(first - 0xd800) << 10) + UInt32(second - 0xdc00)
            } else {
                guard !(0xdc00...0xdfff).contains(first) else { throw LegacyContentError.unsupportedRunStructure(offset: offset) }
                value = UInt32(first)
            }
            guard let scalar = UnicodeScalar(value) else { throw LegacyContentError.unsupportedRunStructure(offset: offset) }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func read(_ stream: FileHandle, offset: UInt64, count: UInt64, end: UInt64) throws -> Data {
        guard offset <= end, count <= end - offset, count <= 1024 * 1024 else {
            throw LegacyContentError.invalidRange(offset: offset)
        }
        try stream.seek(toOffset: offset)
        var data = Data()
        while data.count < Int(count) {
            guard let part = try stream.read(upToCount: Int(count) - data.count), !part.isEmpty else {
                throw LegacyContentError.invalidRange(offset: offset + UInt64(data.count))
            }
            data.append(part)
        }
        return data
    }

    private static func u16(_ data: Data, _ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
    private static func u32(_ data: Data, _ i: Int) -> UInt32 {
        UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
