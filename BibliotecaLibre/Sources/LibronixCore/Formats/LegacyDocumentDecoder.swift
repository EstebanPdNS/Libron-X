import Foundation

/// Paragraph and run discriminators belong to separate factories. 0x101 in
/// the paragraph factory is CTablePara; it is not CInterlinearRun.
struct LegacyDocumentDecoder {
    let data: Data
    let section: LegacySectionDescriptor
    private var cursor = 10
    private var nodes = 0
    private var runs: [LegacyTextRun] = []
    private var anchors: [LegacyReferenceAnchor] = []
    private var markers: [LegacyInlineMarker] = []
    private var graphics: [LegacyGraphicRun] = []
    private var interlinears: [LegacyInterlinearRun] = []
    private var tableCount = 0
    private var cellCount = 0
    private var labels = 0
    private var recoveredClosingReferences = 0

    init(data: Data, section: LegacySectionDescriptor) {
        self.data = data; self.section = section
    }

    mutating func decode() throws -> LegacySectionContent {
        guard data.count >= 20, value32(0) == UInt32(data.count), value16(4) == 17 else { throw unsupported(0) }
        let sourceFlags = value32(6)
        guard sourceFlags & ~0x73 == 0, [1, 3].contains(sourceFlags & 3) else { throw unsupported(0) }
        var rangeIdentifier: UInt32?, rangeEntries: [LegacySectionRangeEntry] = [], referencePrefix: Data?
        // Native article loader reads these bounded prefixes before either
        // paragraph document (0x1412fc99). Bit 0x20 consumes no prefix bytes.
        if sourceFlags & 0x40 != 0 {
            rangeIdentifier = try integer()
            let count = Int(Int16(bitPattern: try word()))
            guard count >= 0, count <= (data.count - cursor) / 10 else { throw unsupported(cursor) }
            for _ in 0..<count {
                let length = Int(Int16(bitPattern: try word()))
                guard length >= 0 else { throw unsupported(cursor) }
                rangeEntries.append(.init(name: try bytes(length), firstPosition: try integer(), secondPosition: try integer()))
            }
        }
        if sourceFlags & 0x10 != 0 { referencePrefix = try bytes(Int(try word())) }
        var documents: [LegacyParagraphDocument] = [], expected: UInt32 = 0, projectedBase = 0
        for flag: UInt32 in [2, 1] where sourceFlags & flag != 0 {
            let document = try readDocument(sourceFlag: flag, projectedBase: projectedBase, nativeBase: expected)
            documents.append(document)
            expected = expected &+ document.declaredCharacterExtentBits
            projectedBase += document.projectedCharacterCount
        }
        guard cursor == data.count else { throw LegacyContentError.characterCountMismatch }
        let paragraphs = documents.flatMap { document in document.paragraphs.map { projected($0, by: document.projectedCharacterBase) } }
        var warnings: [String] = []
        if recoveredClosingReferences > 0 {
            warnings.append("Recovered malformed closing reference metadata: \(recoveredClosingReferences). The raw marker, complete following text and checked paragraph extents are retained; no reference target is invented.")
        }
        for document in documents where !document.hasEmptyExtentSentinel &&
            UInt64(document.projectedCharacterCount) != UInt64(document.declaredCharacterExtentBits) {
            warnings.append("El documento conserva su extensión original (\(document.declaredCharacterExtentBits)) y todo su texto (\(document.projectedCharacterCount) unidades). La proyección plana es incompatible; las posiciones nativas requieren su conversión específica.")
        }
        let tabs = markers.filter { $0.kind == .tab }.count
        let specials = markers.filter { $0.kind == .special }.count
        if tabs > 0 { warnings.append("Se conservan \(tabs) tabulaciones CTabRun (0x21). Las posiciones de tabulación y estilos del original todavía no se reproducen.") }
        if specials > 0 { warnings.append("Se conservan \(specials) elementos CSpecialRun (0x71), sus flags y coordenadas lógicas. RTF, HTML, visibilidad y disposición del original requieren su renderizado específico.") }
        if !graphics.isEmpty { warnings.append("Se conservan \(graphics.count) objetos gráficos CHGraphRun y sus referencias. Escala original, zonas activas y otros formatos siguen pendientes.") }
        if tableCount > 0 { warnings.append("Se conservan \(tableCount) tablas y \(cellCount) celdas con posiciones de lectura. Bordes, medidas, combinaciones de celdas y estilos originales requieren comparación de presentación.") }
        if labels > 0 { warnings.append("Se conservan \(labels) etiquetas de párrafo separadas de sus posiciones de texto. Su presentación y sangrías originales continúan pendientes.") }
        if documents.count > 1 {
            warnings.append("Separate source-flag 2 and 1 document frames are preserved. Their native display roles remain unverified; the text projection adds no boundary character.")
            if UInt64(projectedBase) != UInt64(expected) {
                warnings.append("The complete frame text differs from the native wrapping extent. Flat article locator projection remains incompatible; no source unit was removed or sentinel clamped.")
            }
        }
        return LegacySectionContent(descriptor: section, plainText: documents.map(\.plainText).joined(),
            runs: documents.flatMap { document in document.runs.map { projected($0, by: document.projectedCharacterBase) } },
            expectedCharacterCount: expected,
            recognizedFormat: "LSFF tart: párrafos, tablas, celdas, Unicode por página/UTF-16 y anclas con límites verificados; modo \(section.mode)",
            paragraphs: paragraphs,
            anchors: documents.flatMap { document in document.anchors.map { projected($0, by: document.projectedCharacterBase) } },
            markers: documents.flatMap { document in document.markers.map { projected($0, by: document.projectedCharacterBase) } },
            graphics: documents.flatMap { document in document.graphics.map { projected($0, by: document.projectedCharacterBase) } },
            warnings: warnings, paragraphDocuments: documents,
            storedHeader: .init(flags: sourceFlags, rangeIdentifier: rangeIdentifier, rangeEntries: rangeEntries, referencePrefix: referencePrefix),
            interlinears: documents.flatMap { document in (document.interlinears ?? []).map { projected($0, by: document.projectedCharacterBase) } })
    }

    private mutating func readDocument(sourceFlag: UInt32, projectedBase: Int, nativeBase: UInt32) throws -> LegacyParagraphDocument {
        let begin = cursor
        let version = try word(), count = try word(), opaque = try word(), expected = try integer()
        guard version == 1 else { throw unsupported(begin) }
        guard Int(count) <= (data.count - cursor) / 16 else { throw LegacyContentError.characterCountMismatch }
        let runStart = runs.count, anchorStart = anchors.count, markerStart = markers.count, graphicStart = graphics.count
        let interlinearStart = interlinears.count
        var paragraphs: [LegacyParagraph] = [], parts: [String] = [], characters = 0
        for _ in 0..<count {
            let paragraph = try readParagraph(offset: characters, depth: 0)
            paragraphs.append(paragraph); parts.append(paragraph.text)
            characters += paragraph.logicalCharacterCount
        }
        // CParaDoc reads and retains this declaration independently of its
        // paragraphs (0x14130e28); it does not validate it as a view-text length.
        // Each paragraph and the complete byte cursor remain strictly checked.
        // A mismatching declaration must not delete a source unit or silently
        // authorize flat locators: retain both and expose the incompatibility.
        return LegacyParagraphDocument(sourceFlag: sourceFlag, version: version, opaqueWord: opaque,
            declaredCharacterExtentBits: expected, declaredParagraphCount: count, decodedStart: UInt64(begin),
            decodedEnd: UInt64(cursor), fileOffset: physical(begin), projectedCharacterBase: projectedBase,
            nativeDirectCharacterBaseBits: nativeBase, plainText: parts.joined(separator: "\n"),
            paragraphs: paragraphs, runs: Array(runs[runStart...]), anchors: Array(anchors[anchorStart...]),
            markers: Array(markers[markerStart...]), graphics: Array(graphics[graphicStart...]),
            interlinears: Array(interlinears[interlinearStart...]))
    }

    private func projected(_ run: LegacyTextRun, by base: Int) -> LegacyTextRun {
        LegacyTextRun(text: run.text, controlToken: run.controlToken, styleValue: run.styleValue,
            localeIdentifier: run.localeIdentifier, flags: run.flags, trailingControl: run.trailingControl,
            attribute: run.attribute, characterOffset: run.characterOffset + base, fileOffset: run.fileOffset, decodedOffset: run.decodedOffset,
            extendedAttributes: run.extendedAttributes, extraValue: run.extraValue)
    }
    private func projected(_ anchor: LegacyReferenceAnchor, by base: Int) -> LegacyReferenceAnchor {
        LegacyReferenceAnchor(reference: anchor.reference, flags: anchor.flags, dataTypeCode: anchor.dataTypeCode,
            characterOffset: anchor.characterOffset + base, decodedOffset: anchor.decodedOffset, structuredReference: anchor.structuredReference,
            referenceFormatFlags: anchor.referenceFormatFlags, serializedReference: anchor.serializedReference)
    }
    private func projected(_ marker: LegacyInlineMarker, by base: Int) -> LegacyInlineMarker {
        LegacyInlineMarker(token: marker.token, value: marker.value, sourceRunFlags: marker.sourceRunFlags,
            characterOffset: marker.characterOffset + base, decodedOffset: marker.decodedOffset, fileOffset: marker.fileOffset,
            rawHeaderHex: marker.rawHeaderHex, characterWidth: marker.characterWidth)
    }
    private func projected(_ graphic: LegacyGraphicRun, by base: Int) -> LegacyGraphicRun {
        LegacyGraphicRun(sourceRunFlags: graphic.sourceRunFlags, attribute: graphic.attribute, reference: graphic.reference,
            characterOffset: graphic.characterOffset + base, decodedOffset: graphic.decodedOffset, fileOffset: graphic.fileOffset, rawHeaderHex: graphic.rawHeaderHex,
            extendedAttributes: graphic.extendedAttributes, embeddedData:graphic.embeddedData,embeddedFormat:graphic.embeddedFormat,
            intrinsicWidth:graphic.intrinsicWidth,intrinsicHeight:graphic.intrinsicHeight)
    }
    private func projected(_ unit: LegacyInterlinearRun, by base: Int) -> LegacyInterlinearRun {
        LegacyInterlinearRun(token: unit.token, sourceRunFlags: unit.sourceRunFlags, attribute: unit.attribute,
            extendedAttributes: unit.extendedAttributes, mappingFlags: unit.mappingFlags,
            declaredCharacterCount: unit.declaredCharacterCount, sourceField: unit.sourceField,
            presentLinesMask: unit.presentLinesMask, lines: unit.lines, characterOffset: unit.characterOffset + base,
            decodedOffset: unit.decodedOffset, decodedEnd: unit.decodedEnd, fileOffset: unit.fileOffset)
    }
    private func projected(_ paragraph: LegacyParagraph, by base: Int) -> LegacyParagraph {
        LegacyParagraph(text: paragraph.text, styleIdentifier: paragraph.styleIdentifier, flags: paragraph.flags,
            characterOffset: paragraph.characterOffset + base, declaredCharacterCount: paragraph.declaredCharacterCount,
            kind: paragraph.kind, version: paragraph.version, declaredRunCount: paragraph.declaredRunCount,
            fieldAfterFlags: paragraph.fieldAfterFlags, fieldAfterCount: paragraph.fieldAfterCount, decodedOffset: paragraph.decodedOffset,
            label: paragraph.label, table: paragraph.table.map { projected($0, by: base) },
            children: paragraph.children.map { projected($0, by: base) }, containerVersion: paragraph.containerVersion)
    }
    private func projected(_ table: LegacyTable, by base: Int) -> LegacyTable {
        LegacyTable(version: table.version, sourceField: table.sourceField, overwrittenColumnField: table.overwrittenColumnField,
            columnCount: table.columnCount, rows: table.rows.map { projected($0, by: base) },
            characterOffset: table.characterOffset + base, characterCount: table.characterCount, decodedOffset: table.decodedOffset)
    }
    private func projected(_ row: LegacyTableRow, by base: Int) -> LegacyTableRow {
        LegacyTableRow(version: row.version, flags: row.flags, fields: row.fields, measurements: row.measurements,
            cells: row.cells.map { projected($0, by: base) }, characterOffset: row.characterOffset + base,
            characterCount: row.characterCount, decodedOffset: row.decodedOffset)
    }
    private func projected(_ cell: LegacyTableCell, by base: Int) -> LegacyTableCell {
        LegacyTableCell(version: cell.version, versionFlags: cell.versionFlags, sourceFlags: cell.sourceFlags,
            firstField: cell.firstField, secondField: cell.secondField, extendedField: cell.extendedField,
            firstValue: cell.firstValue, secondValue: cell.secondValue, measurements: cell.measurements,
            content: projected(cell.content, by: base), characterOffset: cell.characterOffset + base,
            characterCount: cell.characterCount, decodedOffset: cell.decodedOffset)
    }

    private mutating func countNode() throws {
        nodes += 1
        guard nodes <= 100_000 else { throw LegacyContentError.contentLimitExceeded }
        if nodes.isMultiple(of: 256) { try Task.checkCancellation() }
    }
    private func ensure(_ count: Int) throws {
        guard count >= 0, cursor <= data.count, count <= data.count - cursor else {
            throw LegacyContentError.invalidRange(offset: section.payloadOffset + UInt64(cursor))
        }
    }
    private func ensureHeader(_ count: Int, at begin: Int) throws {
        guard begin <= data.count, count <= data.count - begin else {
            throw LegacyContentError.invalidRange(offset: section.payloadOffset + UInt64(begin))
        }
    }
    private func unsupported(_ offset: Int) -> LegacyContentError {
        .unsupportedRunStructure(offset: section.payloadOffset + UInt64(offset))
    }
    private func value16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    private func value32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32(8 * $1) }
    }
    private mutating func word() throws -> UInt16 {
        try ensure(2); let result = value16(cursor); cursor += 2; return result
    }
    private mutating func integer() throws -> UInt32 {
        try ensure(4); let result = value32(cursor); cursor += 4; return result
    }
    private mutating func bytes(_ count: Int) throws -> Data {
        try ensure(count); let result = data.subdata(in: cursor..<(cursor + count)); cursor += count; return result
    }
    private func physical(_ offset: Int) -> UInt64? { section.mode == 0 ? section.payloadOffset + UInt64(offset) : nil }

    private mutating func readParagraph(offset: Int, depth: Int, knownKind: LegacyParagraphKind? = nil) throws -> LegacyParagraph {
        try countNode(); try Task.checkCancellation()
        guard depth <= 16 else { throw LegacyContentError.contentLimitExceeded }
        let begin = cursor
        let kind: LegacyParagraphKind
        if let knownKind { kind = knownKind }
        else {
            let tag = try word()
            guard tag == 1 || tag == 0x101 else { throw unsupported(begin) }
            kind = tag == 1 ? .text : .table
        }
        let version = try word(), count = Int(try word()), style = try word(), flags = try word()
        guard version == 1 else { throw unsupported(begin) }
        var label: LegacyParagraphLabel?
        if flags & 3 != 0 {
            let start = cursor
            let parsed = try readRun(offset: 0, capture: false)
            let sourceBytes = data.subdata(in: start..<cursor)
            label = LegacyParagraphLabel(token: parsed.token, text: parsed.text, sourceBytes: sourceBytes,
                decodedOffset: UInt64(start), fileOffset: physical(start), firstField: try word(), secondField: try word())
            labels += 1
        }
        let afterFlags = try word(), declared = try word(), afterCount = try word()
        guard count <= (data.count - cursor) / 2 else { throw LegacyContentError.characterCountMismatch }
        var text = "", bodyCharacters = 0
        for _ in 0..<count {
            let parsed = try readRun(offset: offset + bodyCharacters, capture: true)
            text += parsed.text; bodyCharacters += parsed.text.utf16.count
        }
        var table: LegacyTable?, children: [LegacyParagraph] = [], containerVersion: UInt16?
        switch kind {
        case .text:
            guard bodyCharacters + 1 == Int(declared) else {
                throw LegacyContentError.declaredExtentMismatch(scope: "párrafo", offset: section.payloadOffset + UInt64(begin),
                    expected: UInt32(declared), actual: UInt32(bodyCharacters + 1))
            }
        case .miniList:
            guard count == 0 else { throw unsupported(begin) }
            containerVersion = try word()
            let paragraphs = Int(try word())
            guard paragraphs <= (data.count - cursor) / 14 else { throw LegacyContentError.characterCountMismatch }
            var position = offset
            for _ in 0..<paragraphs {
                let child = try readParagraph(offset: position, depth: depth + 1, knownKind: .text)
                children.append(child); text += child.text + "\n"; position += child.logicalCharacterCount
            }
        case .table:
            guard count == 0 else { throw unsupported(begin) }
            let candidate = try readTable(offset: offset, depth: depth, begin: begin)
            table = candidate.table; text = candidate.text
        }
        return LegacyParagraph(text: text, styleIdentifier: UInt32(style), flags: flags, characterOffset: offset,
            declaredCharacterCount: UInt32(declared), kind: kind, version: version, declaredRunCount: UInt16(count),
            fieldAfterFlags: afterFlags, fieldAfterCount: afterCount, decodedOffset: UInt64(begin), label: label,
            table: table, children: children, containerVersion: containerVersion)
    }

    private mutating func measurement() throws -> LegacyTableMeasurement {
        LegacyTableMeasurement(version: try word(), flags: try word(),
            firstValue: Int16(bitPattern: try word()), secondValue: Int16(bitPattern: try word()), value: try integer())
    }
    private mutating func readTable(offset: Int, depth: Int, begin: Int) throws -> (table: LegacyTable, text: String) {
        let version = try word(), sourceField = try word(), overwritten = try word(), columns = try word(), count = Int(try word())
        guard version == 1 else { throw unsupported(begin) }
        guard count <= 4096, columns <= 256 else { throw LegacyContentError.contentLimitExceeded }
        var rows: [LegacyTableRow] = [], text = "", position = offset
        tableCount += 1
        for _ in 0..<count {
            try countNode()
            let rowBegin = cursor, rowOffset = position
            let rowVersion = try word(), flags = try word()
            var fields: [Int16] = []
            for _ in 0..<3 { fields.append(Int16(bitPattern: try word())) }
            let cells = Int(try word())
            guard cells <= Int(Int16.max), cells <= 256 else { throw LegacyContentError.contentLimitExceeded }
            var measurements: [LegacyTableMeasurement] = []
            for _ in 0..<6 { measurements.append(try measurement()) }
            var decodedCells: [LegacyTableCell] = []
            for _ in 0..<cells {
                let cell = try readCell(offset: position, depth: depth + 1)
                decodedCells.append(cell)
                text += cell.content.text
                if cell.content.kind != .miniList { text += "\n" }
                position += cell.characterCount
            }
            rows.append(LegacyTableRow(version: rowVersion, flags: flags, fields: fields, measurements: measurements,
                cells: decodedCells, characterOffset: rowOffset, characterCount: position - rowOffset, decodedOffset: UInt64(rowBegin)))
        }
        return (LegacyTable(version: version, sourceField: sourceField, overwrittenColumnField: overwritten,
            columnCount: columns, rows: rows, characterOffset: offset, characterCount: position - offset + 1,
            decodedOffset: UInt64(begin)), text)
    }
    private mutating func readCell(offset: Int, depth: Int) throws -> LegacyTableCell {
        try countNode(); cellCount += 1
        let begin = cursor, version = try word()
        guard (1...3).contains(version) else { throw unsupported(begin) }
        let versionFlags: UInt16 = version == 3 ? try word() : 0
        let flags = try word(), first = Int16(bitPattern: try word()), second = Int16(bitPattern: try word())
        let extended: Int16? = version == 2 || versionFlags & 1 != 0 ? Int16(bitPattern: try word()) : nil
        let firstValue = try integer(), secondValue = try integer()
        var measurements: [LegacyTableMeasurement] = []
        for _ in 0..<4 { measurements.append(try measurement()) }
        let content = try readParagraph(offset: offset, depth: depth, knownKind: versionFlags & 2 != 0 ? .miniList : .text)
        return LegacyTableCell(version: version, versionFlags: versionFlags, sourceFlags: flags, firstField: first,
            secondField: second, extendedField: extended, firstValue: firstValue, secondValue: secondValue,
            measurements: measurements, content: content, characterOffset: offset,
            characterCount: content.logicalCharacterCount, decodedOffset: UInt64(begin))
    }

    private mutating func readRun(offset: Int, capture: Bool, depth: Int = 0) throws -> (token: UInt16, text: String) {
        try countNode()
        guard depth <= 8 else { throw LegacyContentError.contentLimitExceeded }
        let begin = cursor, token = try word()
        switch token {
        case 0x201, 0x202:
            return try readInterlinear(token: token, begin: begin, offset: offset, capture: capture, depth: depth)
        case 0x21:
            try ensureHeader(6, at: begin)
            let value = try integer()
            guard value == 0 else { throw unsupported(begin) }
            if capture { markers.append(LegacyInlineMarker(token: token, value: value, sourceRunFlags: 0,
                characterOffset: offset, decodedOffset: UInt64(begin), fileOffset: physical(begin),
                rawHeaderHex: data[begin..<cursor].map { String(format: "%02x", $0) }.joined(), characterWidth: 1)) }
            return (token, "\t")
        case 0x71:
            try ensureHeader(8, at: begin)
            let flags = try word(), value = try integer()
            let marker = LegacyInlineMarker(token: token, value: value, sourceRunFlags: flags,
                characterOffset: offset, decodedOffset: UInt64(begin), fileOffset: physical(begin),
                rawHeaderHex: data[begin..<cursor].map { String(format: "%02x", $0) }.joined(),
                characterWidth: Int(value & 1) + (flags & 0x20 == 0 ? 0 : 1))
            if capture { markers.append(marker) }
            return (token, marker.logicalText)
        case 0x52:
            let flags = try word(), format = try word(), length = Int(try integer())
            // CRefRun2's stream reader consumes length + 1 bytes, including
            // the terminator. Keep the complete source string and flag word;
            // resolving its individual data-type schemes is a separate step.
            guard length <= 1_048_576 else { throw LegacyContentError.contentLimitExceeded }
            let raw = try bytes(length + 1)
            guard raw.last == 0, !raw.dropLast().contains(0) else { throw unsupported(begin) }
            if capture { anchors.append(LegacyReferenceAnchor(
                reference: LegacyResourceReader.decodeCP1252(Data(raw.dropLast())), flags: flags,
                dataTypeCode: format & 1 == 0 ? 0x10 : 0x20, characterOffset: offset, decodedOffset: UInt64(begin),
                referenceFormatFlags: format, serializedReference: raw)) }
            return (token, "")
        case 0x51:
            let flags = try word(), type = try word()
            if type == 4 {
                // Native legacy VNP triples are three signed 16-bit numbers,
                // not a length-prefixed string (0x14132e86).
                var components: [UInt32] = []
                for _ in 0..<3 { components.append(UInt32(bitPattern: Int32(Int16(bitPattern: try word())))) }
                if capture { anchors.append(LegacyReferenceAnchor(reference: nil, flags: flags, dataTypeCode: type,
                    characterOffset: offset, decodedOffset: UInt64(begin),
                    structuredReference: .init(schemeBytes: Data("VNP".utf8), componentBits: components))) }
                return (token, "")
            }
            if type == 8 {
                let payloadStart = cursor
                do {
                    let schemeLength = Int(Int16(bitPattern: try word()))
                    guard (1...20).contains(schemeLength) else { throw unsupported(begin) }
                    let scheme = try bytes(schemeLength)
                    let componentCount = Int(Int16(bitPattern: try word()))
                    guard (1...64).contains(componentCount) else { throw unsupported(begin) }
                    try ensure(componentCount * 4)
                    var components: [UInt32] = []
                    components.reserveCapacity(componentCount)
                    for _ in 0..<componentCount { components.append(try integer()) }
                    if capture { anchors.append(LegacyReferenceAnchor(reference:nil,flags:flags,dataTypeCode:type,
                        characterOffset:offset,decodedOffset:UInt64(begin),structuredReference:LegacyStructuredReference(schemeBytes:scheme,componentBits:components))) }
                    return (token, "")
                } catch {
                    let failure = error
                    cursor = payloadStart
                    // A damaged closing marker may lack its serialized CScr.
                    // Recover only a fully checked following text run. The outer
                    // run count, paragraph extent and complete document cursor
                    // still have to agree; no printable-text scanning is used.
                    guard flags & 0x80 != 0, cursor <= data.count-2,
                          [0x11,0x12,0x13].contains(value16(cursor)) else { throw failure }
                    var probe = self
                    guard let next = try? probe.readRun(offset:offset,capture:false,depth:depth+1), !next.text.isEmpty else { throw failure }
                    recoveredClosingReferences += 1
                    if capture { anchors.append(LegacyReferenceAnchor(reference:nil,flags:flags,dataTypeCode:type,
                        characterOffset:offset,decodedOffset:UInt64(begin),serializedReference:data.subdata(in:begin..<payloadStart))) }
                    return (token, "")
                }
            }
            let length = Int(try word())
            let reference = LegacyResourceReader.decodeCP1252(try bytes(length))
            if capture { anchors.append(LegacyReferenceAnchor(reference: reference, flags: flags, dataTypeCode: type,
                characterOffset: offset, decodedOffset: UInt64(begin))) }
            return (token, "")
        case 0x31:
            // CWMFRun stream constructor 0x14131f0e: shared attributes,
            // signed x/y extents, byte count, then the exact metafile bytes.
            let (flags,attribute,extended) = try sharedAttributes()
            let width = Int(Int16(bitPattern:try word())), height = Int(Int16(bitPattern:try word()))
            let length = Int(try integer()), headerEnd = cursor
            guard length > 0, length <= 16*1024*1024 else { throw LegacyContentError.contentLimitExceeded }
            let embedded = try bytes(length)
            let graphic = LegacyGraphicRun(sourceRunFlags:flags,attribute:attribute,reference:"!embedded-\(section.ordinal)-\(begin).wmf",
                characterOffset:offset,decodedOffset:UInt64(begin),fileOffset:physical(begin),
                rawHeaderHex:data[begin..<headerEnd].map { String(format:"%02x",$0) }.joined(),extendedAttributes:extended,
                embeddedData:embedded,embeddedFormat:"wmf",intrinsicWidth:width,intrinsicHeight:height)
            if capture { graphics.append(graphic) }
            return (token,graphic.logicalText)
        case 0x61:
            try ensureHeader(6, at: begin)
            let (flags, attribute, extended) = try sharedAttributes()
            let referenceLength = Int(try word())
            guard referenceLength > 0 else { throw unsupported(begin) }
            let reference = LegacyResourceReader.decodeCP1252(try bytes(referenceLength))
            let graphic = LegacyGraphicRun(sourceRunFlags: flags, attribute: attribute, reference: reference,
                characterOffset: offset, decodedOffset: UInt64(begin), fileOffset: physical(begin),
                rawHeaderHex: data[begin..<cursor].map { String(format: "%02x", $0) }.joined(), extendedAttributes: extended)
            if capture { graphics.append(graphic) }
            return (token, graphic.logicalText)
        case 0x11, 0x12, 0x13:
            let flags: UInt16, locale: UInt16, attribute: String?, length: Int
            let extended: LegacyRunAttributes?, extra: UInt32?
            if token != 0x12 {
                (flags, attribute, extended) = try sharedAttributes()
                extra = token == 0x13 ? try integer() : nil
                length = Int(try word()); locale = try word()
            } else { flags = 0; attribute = nil; extended = nil; extra = nil; length = Int(try word()); locale = 1033 }
            guard length <= Int(Int16.max) else { throw unsupported(begin) }
            // Native CCharRun skips LString storage, including its page byte,
            // when a normal run has zero stored units. The style still follows.
            // The compact 0x12 branch retains its separate storage contract.
            let page: UInt8 = token != 0x12 && length == 0 ? 0 : try bytes(1)[0]
            try ensure((page == 0xf0 ? length * 2 : length) + (token != 0x12 ? 2 : 1))
            let encoded = try bytes(page == 0xf0 ? length * 2 : length)
            let trailing = token != 0x12 ? try word() : UInt16(try bytes(1)[0])
            let text = page == 0xf0 ? try LegacyContentReader.decodeUTF16(encoded, offset: section.payloadOffset + UInt64(begin))
                : try LegacyContentReader.decodeUnicodePage(encoded, page: page, offset: section.payloadOffset + UInt64(begin))
            let run = LegacyTextRun(text: text, controlToken: token, styleValue: UInt32(flags), localeIdentifier: locale,
                flags: page, trailingControl: trailing, attribute: attribute, characterOffset: offset,
                fileOffset: physical(begin), decodedOffset: UInt64(begin), extendedAttributes: extended, extraValue: extra)
            if capture { runs.append(run) }
            return (token, run.logicalText)
        default: throw unsupported(begin)
        }
    }

    private mutating func readInterlinear(token: UInt16, begin: Int, offset: Int, capture: Bool,
                                         depth: Int) throws -> (token: UInt16, text: String) {
        let flags: UInt16, attribute: String?, extended: LegacyRunAttributes?, mappingFlags: UInt16
        if token == 0x202 {
            (flags, attribute, extended) = try sharedAttributes(); mappingFlags = try word()
        } else { flags = try word(); attribute = nil; extended = nil; mappingFlags = 0 }
        let count = Int(Int16(bitPattern: try word())), declared = try integer(), field = try word(), mask = try integer()
        guard (1...32).contains(count), declared == UInt32.max || declared <= 1_048_576 else { throw unsupported(begin) }
        var lines: [LegacyInterlinearLine] = []
        for ordinal in 0..<count {
            try countNode()
            let present = mask & (UInt32(1) << ordinal) != 0
            let runStart = runs.count, anchorStart = anchors.count, markerStart = markers.count
            let graphicStart = graphics.count, interlinearStart = interlinears.count
            var text = "", mappings: [LegacyInterlinearMapping] = []
            if present {
                let runCount = Int(Int16(bitPattern: try word()))
                guard runCount >= 0, runCount <= (data.count - cursor) / 2 else { throw unsupported(cursor) }
                for _ in 0..<runCount {
                    let part = try readRun(offset: text.utf16.count, capture: true, depth: depth + 1)
                    text += part.text
                }
                if mappingFlags & 1 != 0 {
                    let mappingCount = Int(Int16(bitPattern: try word()))
                    guard mappingCount >= 0, mappingCount <= (data.count - cursor) / 4 else { throw unsupported(cursor) }
                    for _ in 0..<mappingCount { mappings.append(.init(first: try word(), second: try word())) }
                }
            }
            lines.append(.init(ordinal: ordinal, isSerialized: present, text: text,
                runs: Array(runs[runStart...]), anchors: Array(anchors[anchorStart...]),
                markers: Array(markers[markerStart...]), graphics: Array(graphics[graphicStart...]),
                interlinears: Array(interlinears[interlinearStart...]), mappings: mappings))
            runs.removeSubrange(runStart...); anchors.removeSubrange(anchorStart...); markers.removeSubrange(markerStart...)
            graphics.removeSubrange(graphicStart...); interlinears.removeSubrange(interlinearStart...)
        }
        let unit = LegacyInterlinearRun(token: token, sourceRunFlags: flags, attribute: attribute, extendedAttributes: extended,
            mappingFlags: mappingFlags, declaredCharacterCount: declared, sourceField: field, presentLinesMask: mask,
            lines: lines, characterOffset: offset, decodedOffset: UInt64(begin), decodedEnd: UInt64(cursor), fileOffset: physical(begin))
        guard declared == UInt32.max || unit.surfaceText.utf16.count == Int(declared) else {
            throw LegacyContentError.declaredExtentMismatch(scope: "interlineal", offset: section.payloadOffset + UInt64(begin),
                expected: declared, actual: UInt32(unit.surfaceText.utf16.count))
        }
        if capture {
            interlinears.append(unit)
            let base = unit.surfaceCharacterOffset
            let surface = lines[0]
            runs += surface.runs.map { projected($0, by: base) }
            anchors += surface.anchors.map { projected($0, by: base) }
            markers += surface.markers.map { projected($0, by: base) }
            graphics += surface.graphics.map { projected($0, by: base) }
        }
        return (token, unit.logicalText)
    }

    private mutating func sharedAttributes() throws -> (UInt16, String?, LegacyRunAttributes?) {
        let flags = try word(), length = Int(try word())
        if length != 0xf00d {
            return (flags, length == 0 ? nil : LegacyResourceReader.decodeCP1252(try bytes(length)), nil)
        }
        let extensionFlags = try word()
        let raw = extensionFlags == 0 ? Data() : try bytes(Int(try word()))
        var at = 0, strings: [Data] = [], values: [UInt32] = []
        func signedCount() throws -> Int {
            guard at <= raw.count - 2 else { throw unsupported(cursor) }
            let value = Int(Int16(bitPattern: UInt16(raw[at]) | UInt16(raw[at + 1]) << 8)); at += 2
            guard value >= 0 else { throw unsupported(cursor) }; return value
        }
        if !raw.isEmpty {
            if extensionFlags & 1 != 0 {
                let count = try signedCount()
                for _ in 0..<count {
                    let length = try signedCount()
                    guard length <= raw.count - at else { throw unsupported(cursor) }
                    strings.append(raw.subdata(in: at..<(at + length))); at += length
                }
            }
            if extensionFlags & 2 != 0 {
                let count = try signedCount()
                guard count <= (raw.count - at) / 4 else { throw unsupported(cursor) }
                for _ in 0..<count {
                    values.append((0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[at + $1]) << ($1 * 8) }); at += 4
                }
            }
        }
        return (flags, nil, LegacyRunAttributes(flags: extensionFlags, rawData: raw, strings: strings,
                                               values: values, unparsedTail: raw.subdata(in: at..<raw.count)))
    }
}
