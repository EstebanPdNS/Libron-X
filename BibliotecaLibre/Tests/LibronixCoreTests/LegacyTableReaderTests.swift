import Foundation
import Testing
@testable import LibronixCore

struct LegacyTableReaderTests {
    @Test func tableCellsKeepSourceOrderUnicodeAndArticleCoordinates() throws {
        let source = TableWire.article([TableWire.paragraph("Before"),
            TableWire.table([[TableWire.cell("😀α", anchor: "ge 1:1"), TableWire.cell("B")],
                             [TableWire.cell("C"), TableWire.cell("After")]]), TableWire.paragraph("End")])
        let content = try TableWire.decode(source)
        #expect(content.plainText == "Before\n😀α\nB\nC\nAfter\n\nEnd")
        #expect(content.expectedCharacterCount == 25)
        let table = try #require(content.tables.first)
        #expect(table.columnCount == 2 && table.rows.count == 2 && table.characterCount == 15)
        #expect(table.characterOffset == 7)
        #expect(table.rows.map(\.characterOffset) == [7, 13])
        #expect(table.rows.flatMap(\.cells).map(\.characterOffset) == [7, 11, 13, 15])
        #expect(table.rows.flatMap(\.cells).map(\.characterCount) == [4, 2, 2, 6])
        #expect(content.runs.map(\.characterOffset) == [0, 7, 11, 13, 15, 22])
        #expect(content.anchors.first?.characterOffset == 7)
        #expect(table.rows[0].measurements.count == 6 && table.rows[0].cells[0].measurements.count == 4)
        #expect(table.rows[0].cells[0].content.styleIdentifier == 42)
    }

    @Test func aMultiParagraphCellDoesNotAddAnInventedSeparator() throws {
        let mini = TableWire.mini([TableWire.paragraph("A", tagged: false), TableWire.paragraph("BC", tagged: false)])
        let source = TableWire.article([TableWire.table([[TableWire.cellBody(mini, version: 3, bits: 2)]])])
        let content = try TableWire.decode(source)
        #expect(content.plainText == "A\nBC\n" && content.expectedCharacterCount == 5)
        let cell = try #require(content.tables.first?.rows.first?.cells.first)
        #expect(cell.content.kind == .miniList && cell.content.containerVersion == 1)
        #expect(cell.content.children.map(\.characterOffset) == [0, 2])
        #expect(cell.characterCount == 5 && cell.content.logicalCharacterCount == 5)
        #expect(cell.content.declaredCharacterCount == 0)
        // The original mini-list constructor recalculates its length from
        // children; the serialized base field remains preserved separately.
        #expect(content.paragraphs[0].logicalCharacterCount == 6)
    }

    @Test func listLabelsAndAuxiliaryHeaderWordsDoNotShiftBodyPositions() throws {
        for flags: UInt16 in [1, 2, 3] {
            let source = TableWire.article([TableWire.paragraph("Body", flags: flags, label: "•", afterFlags: 12, afterCount: 9)])
            let content = try TableWire.decode(source)
            let paragraph = try #require(content.paragraphs.first), label = try #require(paragraph.label)
            #expect(content.plainText == "Body" && content.expectedCharacterCount == 4)
            #expect(content.runs.count == 1 && content.runs[0].characterOffset == 0)
            #expect(paragraph.flags == flags && paragraph.fieldAfterFlags == 12 && paragraph.fieldAfterCount == 9)
            #expect(paragraph.styleIdentifier == 42 && label.text == "•")
            #expect(label.firstField == 20 && label.secondField == 30 && !label.sourceBytes.isEmpty)
        }
    }

    @Test func extendedCellVariantsPreserveEveryFieldWithoutGuessingSpans() throws {
        let mini = TableWire.mini([TableWire.paragraph("V3", tagged: false)])
        let source = TableWire.article([TableWire.table([[TableWire.cellBody(TableWire.paragraph("V2", tagged: false), version: 2),
            TableWire.cellBody(mini, version: 3, bits: 3)]])])
        let content = try TableWire.decode(source)
        let cells = try #require(content.tables.first?.rows.first?.cells)
        #expect(cells.map(\.version) == [2, 3] && cells.map(\.versionFlags) == [0, 3])
        #expect(cells.map(\.extendedField) == [2, 2])
        #expect(cells[0].firstValue == 0x11223344 && cells[0].secondValue == 0x55667788)
        #expect(cells[0].firstField == 6480 && cells[0].secondField == 2000)
        #expect(cells[0].measurements[0].firstValue == -2 && cells[0].measurements[0].value == 120)
        #expect(content.plainText == "V2\nV3\n")
    }

    @Test func malformedCellLengthsVersionsAndLimitsRejectTheWholeArticle() throws {
        let valid = TableWire.article([TableWire.table([[TableWire.cell("X")]])])
        var wrongCount = valid; wrongCount[204] = 9
        var unknownCell = valid; unknownCell[130] = 4
        var oversized = valid; oversized.replaceSubrange(42..<44, with: TableWire.word(257))
        var truncated = valid; truncated.removeLast(4); truncated.replaceSubrange(0..<4, with: TableWire.integer(UInt32(truncated.count)))
        for bad in [wrongCount, unknownCell, oversized, truncated] {
            #expect(throws: (any Error).self) { try TableWire.decode(bad) }
        }
    }

    @Test func tableBytePositionsDoNotBecomePhysicalOffsetsForCompressedSections() throws {
        let source = TableWire.article([TableWire.table([[TableWire.cell("Text")]])])
        let plain = try TableWire.decode(source), compressed = try TableWire.decode(source, mode: 1)
        #expect(plain.plainText == compressed.plainText)
        #expect(plain.runs[0].fileOffset == 100 + plain.runs[0].decodedOffset)
        #expect(compressed.runs[0].fileOffset == nil)
        #expect(plain.tables[0].rows[0].cells[0].decodedOffset == 130)
        #expect(plain.runs[0].decodedOffset == 208)
    }
}

/// Synthetic wire records derived from the observed factories. No books,
/// binaries, installed libraries or network services are test dependencies.
private enum TableWire {
    struct Part { let bytes: Data; let width: Int }
    static func word(_ n: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)]) }
    static func integer(_ n: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> UInt32(8 * $0)) }) }
    static func run(_ text: String) -> Data {
        word(17) + word(0) + word(0) + word(UInt16(text.utf16.count)) + word(1033) + Data([0xf0])
            + Data(text.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }) + word(3)
    }
    static func paragraph(_ text: String, tagged: Bool = true, flags: UInt16 = 0, label: String? = nil,
                          afterFlags: UInt16 = 0, afterCount: UInt16 = 0, anchor: String? = nil) -> Part {
        let mark = anchor.map { word(81) + word(0) + word(2) + word(UInt16($0.utf8.count)) + Data($0.utf8) } ?? Data()
        var header = (tagged ? word(1) : Data()) + word(1) + word(anchor == nil ? 1 : 2) + word(42) + word(flags)
        if let label { header += run(label) + word(20) + word(30) }
        header += word(afterFlags) + word(UInt16(text.utf16.count + 1)) + word(afterCount)
        return Part(bytes: header + mark + run(text), width: text.utf16.count + 1)
    }
    static func measurement() -> Data { word(1) + word(0) + word(0xfffe) + word(4) + integer(120) }
    static func cell(_ text: String, anchor: String? = nil) -> Part { cellBody(paragraph(text, tagged: false, anchor: anchor)) }
    static func cellBody(_ body: Part, version: UInt16 = 1, bits: UInt16 = 0) -> Part {
        var header = word(version) + (version == 3 ? word(bits) : Data()) + word(0) + word(6480) + word(2000)
        if version == 2 || bits & 1 != 0 { header += word(2) }
        header += integer(0x11223344) + integer(0x55667788)
        for _ in 0..<4 { header += measurement() }
        return Part(bytes: header + body.bytes, width: body.width)
    }
    static func mini(_ paragraphs: [Part]) -> Part {
        let common = word(1) + word(0) + word(42) + word(0) + word(0) + word(0) + word(0)
        return Part(bytes: common + word(1) + word(UInt16(paragraphs.count)) + paragraphs.reduce(Data()) { $0 + $1.bytes },
                    width: paragraphs.reduce(0) { $0 + $1.width })
    }
    static func table(_ rows: [[Part]]) -> Part {
        let width = rows.flatMap { $0 }.reduce(1) { $0 + $1.width }
        var data = word(0x101) + word(1) + word(0) + word(10024) + word(0) + word(0) + word(UInt16(width)) + word(0)
        data += word(1) + word(2) + word(UInt16(rows.first?.count ?? 0)) + word(UInt16(rows.first?.count ?? 0)) + word(UInt16(rows.count))
        for row in rows {
            data += word(1) + word(0) + word(0) + word(0) + word(0) + word(UInt16(row.count))
            for _ in 0..<6 { data += measurement() }
            for cell in row { data += cell.bytes }
        }
        return Part(bytes: data, width: width)
    }
    static func article(_ paragraphs: [Part]) -> Data {
        var data = Data(repeating: 0, count: 4) + word(17) + integer(1) + word(1) + word(UInt16(paragraphs.count))
            + word(0) + integer(UInt32(paragraphs.reduce(0) { $0 + $1.width } - 1))
        for paragraph in paragraphs { data += paragraph.bytes }
        data.replaceSubrange(0..<4, with: integer(UInt32(data.count)))
        return data
    }
    static func decode(_ data: Data, mode: UInt16 = 0) throws -> LegacySectionContent {
        let descriptor = LegacySectionDescriptor(ordinal: 0, headerOffset: 94, payloadOffset: 100,
            storedLength: UInt32(data.count), decodedLength: UInt32(data.count), mode: mode, codecWord: mode == 0 ? nil : 0)
        return try LegacyContentReader.decodeSimpleLatinRuns(data, section: descriptor)
    }
}
