import Foundation
import Testing
@testable import LibronixCore

struct LegacyCompoundDocumentTests {
    @Test func twentyByteSingleEmptyDocumentRetainsItsSentinel() throws {
        let data = single(document([]))
        #expect(data.count == 20)
        let content = try decode(data), frames = try #require(content.paragraphDocuments)
        #expect(frames.count == 1 && frames[0].sourceFlag == 1 && frames[0].hasEmptyExtentSentinel)
        #expect(content.plainText.isEmpty && content.expectedCharacterCount == UInt32.max)
        #expect(!content.hasCompatibleFlatTextProjection && content.initialDirectDocumentPosition(forArticlePosition: 0)?.localPosition == 0)
        var invalid = data; invalid.replaceSubrange(16..<20, with: integer(0))
        let retained = try decode(invalid)
        #expect(retained.plainText.isEmpty && retained.paragraphDocuments?.last?.declaredCharacterExtentBits == 0)
    }

    @Test func thirtyByteCompoundEmptyDocumentKeepsBothFramesAndWrappingExtent() throws {
        let data = compound(document([]), document([]))
        #expect(data.count == 30)
        let content = try decode(data), frames = try #require(content.paragraphDocuments)
        #expect(frames.map(\.sourceFlag) == [2, 1] && frames.allSatisfy(\.hasEmptyExtentSentinel))
        #expect(frames.map(\.decodedStart) == [10, 20] && frames.map(\.decodedEnd) == [20, 30])
        #expect(content.plainText.isEmpty && content.expectedCharacterCount == UInt32.max - 1)
        #expect(!content.hasCompatibleFlatTextProjection && content.initialDirectDocumentPosition(forArticlePosition: 0) == nil)
        var invalid = data; invalid.replaceSubrange(26..<30, with: integer(0))
        let retained = try decode(invalid)
        #expect(retained.plainText.isEmpty && retained.paragraphDocuments?.last?.declaredCharacterExtentBits == 0)
    }

    @Test func nativeFrameOrderAndByteBoundariesRemainSeparate() throws {
        let content = try decode(compound(document([paragraph("Q")], opaque: 0xabcd), document([paragraph("R")], opaque: 0x1234)))
        let frames = try #require(content.paragraphDocuments)
        #expect(frames.map(\.sourceFlag) == [2, 1])
        #expect(frames.map(\.opaqueWord) == [0xabcd, 0x1234])
        #expect(frames.map(\.decodedStart) == [10, 51])
        #expect(frames.map(\.decodedEnd) == [51, 92])
        #expect(frames.map(\.fileOffset) == [110, 151])
        #expect(frames.map(\.plainText) == ["Q", "R"])
        #expect(content.plainText == "QR" && content.expectedCharacterCount == 2)
        #expect(content.hasCompatibleFlatTextProjection && content.documentSourceFlags == 3)
        #expect(content.paragraphs.map(\.characterOffset) == [0, 1])
        #expect(content.runs.map(\.characterOffset) == [0, 1])
        #expect(frames.allSatisfy { $0.paragraphs[0].characterOffset == 0 && $0.runs[0].characterOffset == 0 })
    }

    @Test func unicodeAnchorsAndMarkersUseViewOffsetsWithoutChangingLocalCoordinates() throws {
        var page = words([0x51, 128, 8, 1]); page.append(0x50); page.append(words([1])); page.append(integer(6))
        let tab = words([0x21]) + integer(0)
        let first = document([paragraph("漢😀")])
        let second = document([paragraphRuns([page, text("R"), tab], characters: 2)])
        let content = try decode(compound(first, second))
        let frames = try #require(content.paragraphDocuments)
        #expect(content.plainText == "漢😀R\t" && content.expectedCharacterCount == 5)
        #expect(frames[1].projectedCharacterBase == 3 && frames[1].nativeDirectCharacterBase == 3)
        #expect(frames[1].anchors[0].characterOffset == 0 && content.anchors[0].characterOffset == 3)
        #expect(frames[1].markers[0].characterOffset == 1 && content.markers[0].characterOffset == 4)
        #expect(content.runs.map(\.characterOffset) == [0, 3])
        #expect(content.anchors[0].structuredReference?.componentBits == [6])
        #expect(content.anchors[0].decodedOffset == frames[1].anchors[0].decodedOffset)
        #expect(content.initialDirectDocumentPosition(forArticlePosition: 2)?.sourceFlag == 2)
        #expect(content.initialDirectDocumentPosition(forArticlePosition: 3) == LegacyDirectDocumentPosition(sourceFlag: 1, localPosition: 0))
    }

    @Test func multipleParagraphsDoNotInventAFrameBoundaryNewline() throws {
        let content = try decode(compound(document([paragraph("Q"), paragraph("R")]), document([paragraph("S")])))
        let frames = try #require(content.paragraphDocuments)
        #expect(content.plainText == "Q\nRS" && content.expectedCharacterCount == 4)
        #expect(frames[0].plainText == "Q\nR" && frames[0].declaredCharacterExtentBits == 3)
        #expect(content.paragraphs.map(\.characterOffset) == [0, 2, 3])
        #expect(content.initialDirectDocumentPosition(forArticlePosition: 3)?.localPosition == 0)
    }

    @Test func emptyFirstFrameKeepsSentinelAndTheUnmappedPrefix() throws {
        let content = try decode(compound(document([]), document([paragraph("QR")])))
        let frames = try #require(content.paragraphDocuments)
        #expect(frames[0].hasEmptyExtentSentinel && frames[0].plainText.isEmpty)
        #expect(frames[0].declaredCharacterExtentBits == UInt32.max && frames[0].decodedEnd == 20)
        #expect(frames[1].plainText == "QR" && content.plainText == "QR")
        #expect(frames[1].nativeDirectCharacterBase == -1 && frames[1].projectedCharacterBase == 0)
        #expect(content.expectedCharacterCount == 1 && !content.hasCompatibleFlatTextProjection)
        #expect(frames[1].runs[0].characterOffset == 0 && content.runs[0].characterOffset == 0)
        #expect(content.initialDirectDocumentPosition(forArticlePosition: 0) == LegacyDirectDocumentPosition(sourceFlag: 1, localPosition: 1))
        #expect(frames[1].initialDirectArticlePosition(localPosition: 0) == -1)
        #expect(frames[1].initialDirectArticlePosition(localPosition: 1) == 0)
        #expect(content.warnings.contains { $0.contains("incompatible") })
    }

    @Test func emptySecondFrameRetainsItsOwnSentinelWithoutClamping() throws {
        let content = try decode(compound(document([paragraph("Q")]), document([])))
        let frames = try #require(content.paragraphDocuments)
        #expect(frames[1].hasEmptyExtentSentinel && frames[1].plainText.isEmpty)
        #expect(content.plainText == "Q" && content.expectedCharacterCount == 0)
        #expect(!content.hasCompatibleFlatTextProjection)
    }

    @Test func compressedDecodedCoordinatesNeverBecomePhysicalFileOffsets() throws {
        let data = compound(document([paragraph("Q")]), document([paragraph("R")]))
        let content = try decode(data, mode: 1), plain = try decode(data)
        let frames = try #require(content.paragraphDocuments)
        #expect(frames.map(\.decodedStart) == plain.paragraphDocuments?.map(\.decodedStart))
        #expect(frames.allSatisfy { $0.fileOffset == nil && $0.runs.allSatisfy { $0.fileOffset == nil } })
        #expect(content.plainText == plain.plainText && content.runs.map(\.characterOffset) == [0, 1])
    }

    @Test func malformedSecondFramesCannotReturnPartiallySuccessfulContent() throws {
        let first = document([paragraph("Q")]), second = document([paragraph("R")])
        let boundary = 10 + first.count
        var negative = compound(first, second); negative.replaceSubrange((boundary + 2)..<(boundary + 4), with: words([UInt16.max]))
        var version = compound(first, second); version.replaceSubrange(boundary..<(boundary + 2), with: words([2]))
        for bad in [compound(first, Data(second.prefix(7))), compound(first, Data(second.dropLast(3))),
                    negative, version, compound(first, second + Data([0]))] {
            #expect(throws: (any Error).self) { try decode(bad) }
        }
    }

    @Test func nativeDocumentExtentIsRetainedIndependentlyOfTheCompleteTextProjection() throws {
        let first = document([paragraph("Q")]), second = document([paragraph("R")])
        var data = compound(first, second)
        let boundary = 10 + first.count
        data.replaceSubrange((boundary + 6)..<(boundary + 10), with: integer(9))
        let content = try decode(data)
        #expect(content.plainText == "QR" && content.expectedCharacterCount == 10)
        #expect(content.paragraphDocuments?.last?.declaredCharacterExtentBits == 9)
        #expect(!content.hasCompatibleFlatTextProjection)
        #expect(content.warnings.contains { $0.contains("incompatible") })
        #expect(content.runs.map(\.characterOffset) == [0, 1])
    }

    @Test func unknownOuterFlagsRemainExplicitRejections() throws {
        for flags: UInt32 in [0, 2, 4, 0x81, 0x101] {
            var data = compound(document([paragraph("Q")]), document([paragraph("R")]))
            data.replaceSubrange(6..<10, with: integer(flags))
            #expect(throws: LegacyContentError.unsupportedRunStructure(offset: 100)) { try decode(data) }
        }
    }

    @Test func singleDocumentAndOldJSONKeepTheirExistingProjection() throws {
        let data = single(document([paragraph("漢😀")]))
        let content = try decode(data)
        #expect(content.plainText == "漢😀" && content.expectedCharacterCount == 3)
        #expect(content.paragraphDocuments?.map(\.sourceFlag) == [1])
        #expect(content.runs[0].decodedOffset == 36 && content.runs[0].characterOffset == 0)
        let restored = try JSONDecoder().decode(LegacySectionContent.self, from: JSONEncoder().encode(content))
        #expect(restored == content)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as! [String: Any]
        object.removeValue(forKey: "paragraphDocuments")
        let old = try JSONDecoder().decode(LegacySectionContent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.paragraphDocuments == nil && old.plainText == content.plainText && old.runs == content.runs)
    }

    @Test func directRouterBoundsRemainSeparateFromVirtualMappingAndTextValidity() throws {
        let content = try decode(compound(document([paragraph("Q")]), document([paragraph("R")])))
        #expect(content.initialDirectDocumentPosition(forArticlePosition: -1) == nil)
        #expect(content.initialDirectDocumentPosition(forArticlePosition: 3) == nil)
        #expect(content.initialDirectDocumentPosition(forArticlePosition: 0) == LegacyDirectDocumentPosition(sourceFlag: 2, localPosition: 0))
        #expect(content.initialDirectDocumentPosition(forArticlePosition: 1) == LegacyDirectDocumentPosition(sourceFlag: 1, localPosition: 0))
        #expect(content.initialDirectDocumentPosition(forArticlePosition: 2) == LegacyDirectDocumentPosition(sourceFlag: 1, localPosition: 1))
    }

    @Test func nestedTablePositionsAreRebasedOnlyInTheFlatView() throws {
        let table = oneCellTable("R")
        let content = try decode(compound(document([paragraph("Q")]), document([table])))
        let frames = try #require(content.paragraphDocuments)
        let local = try #require(frames[1].paragraphs[0].table), projected = try #require(content.tables.first)
        #expect(content.plainText == "QR\n" && content.expectedCharacterCount == 3)
        #expect(local.characterOffset == 0 && projected.characterOffset == 1)
        #expect(local.rows[0].characterOffset == 0 && projected.rows[0].characterOffset == 1)
        #expect(local.rows[0].cells[0].content.characterOffset == 0 && projected.rows[0].cells[0].content.characterOffset == 1)
        #expect(local.decodedOffset == projected.decodedOffset)
        #expect(content.runs.map(\.characterOffset) == [0, 1])
    }

    private struct Part { let bytes: Data; let characters: Int }
    private func paragraph(_ value: String) -> Part { paragraphRuns([text(value)], characters: value.utf16.count) }
    private func paragraphRuns(_ runs: [Data], characters: Int) -> Part {
        Part(bytes: words([1, 1, UInt16(runs.count), 0, 0, 0, UInt16(characters + 1), 0])
            + runs.reduce(Data(), +), characters: characters + 1)
    }
    private func text(_ value: String) -> Data {
        let units = Array(value.utf16)
        var data = words([0x11, 0, 0, UInt16(units.count), 1033])
        if !units.isEmpty { data.append(0xf0); data.append(words(units)) }
        data.append(words([0])); return data
    }
    private func oneCellTable(_ value: String) -> Part {
        let measurement = words([1, 0, 0, 0]) + integer(120)
        let body = words([1, 1, 0, 0, 0, UInt16(value.utf16.count + 1), 0]) + text(value)
        var cell = words([1, 0, 0, 0]) + integer(0) + integer(0)
        for _ in 0..<4 { cell.append(measurement) }
        cell.append(body)
        var row = words([1, 0, 0, 0, 0, 1])
        for _ in 0..<6 { row.append(measurement) }
        row.append(cell)
        let count = value.utf16.count + 2
        return Part(bytes: words([0x101, 1, 0, 0, 0, 0, UInt16(count), 0]) + words([1, 0, 1, 1, 1]) + row, characters: count)
    }
    private func document(_ paragraphs: [Part], opaque: UInt16 = 0) -> Data {
        let count = paragraphs.reduce(0) { $0 + $1.characters }
        return words([1, UInt16(paragraphs.count), opaque]) + integer(count == 0 ? UInt32.max : UInt32(count - 1))
            + paragraphs.reduce(Data()) { $0 + $1.bytes }
    }
    private func compound(_ first: Data, _ second: Data) -> Data { container(flags: 3, frames: first + second) }
    private func single(_ frame: Data) -> Data { container(flags: 1, frames: frame) }
    private func container(flags: UInt32, frames: Data) -> Data {
        let data = integer(0) + words([17]) + integer(flags) + frames
        return integer(UInt32(data.count)) + data.dropFirst(4)
    }
    private func words(_ values: [UInt16]) -> Data { Data(values.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }) }
    private func integer(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) }) }
    private func decode(_ data: Data, mode: UInt16 = 0) throws -> LegacySectionContent {
        let section = LegacySectionDescriptor(ordinal: 0, headerOffset: 94, payloadOffset: 100,
            storedLength: UInt32(data.count), decodedLength: UInt32(data.count), mode: mode, codecWord: mode == 0 ? nil : 0)
        return try LegacyContentReader.decodeSimpleLatinRuns(data, section: section)
    }
}
