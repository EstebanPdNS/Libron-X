import Foundation
import Testing
@testable import LibronixCore

struct LegacyContentReaderTests {
    @Test func decodesSyntheticLatinRunsAndKeepsControlProvenance() throws {
        let data = payload([(Data("One ".utf8), 1033, 0, 0), (Data("two".utf8), 1033, 7, 1)])
        let descriptor = section(length: data.count)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: descriptor)
        #expect(result.plainText == "One two")
        #expect(result.expectedCharacterCount == 7)
        #expect(result.runs.count == 2)
        #expect(result.runs[1].styleValue == 7)
        #expect(result.runs[1].trailingControl == 1)
        #expect(result.runs[0].fileOffset == descriptor.payloadOffset + 36)
    }

    @Test func recognizesCP1252AccentsWithoutSearchingPrintableRuns() throws {
        let data = payload([(Data([0x47, 0x75, 0xed, 0x61]), 1034, 0, 0)])
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "Guía")
    }

    @Test func decodesStorageUnicodeIndependentlyOfTheLanguageSelector() throws {
        var hebrew = payload([(Data([0xd0, 0xd1]), 1037, 0, 0)])
        hebrew[46] = 5
        let decoded = try LegacyContentReader.decodeSimpleLatinRuns(hebrew, section: section(length: hebrew.count))
        #expect(decoded.plainText == "אב")
        #expect(decoded.runs[0].localeIdentifier == 1037)
        #expect(decoded.runs[0].textEncodingPage == 5)
        let strong = payload([(Data("123".utf8), 257, 0, 0)])
        #expect(try LegacyContentReader.decodeSimpleLatinRuns(strong, section: section(length: strong.count)).plainText == "123")
        var unknownSelector = payload([(Data([0xb1]), UInt16.max, 0, 0)])
        unknownSelector[46] = 3
        let preserved = try LegacyContentReader.decodeSimpleLatinRuns(unknownSelector, section: section(length: unknownSelector.count))
        #expect(preserved.plainText == "α")
        #expect(preserved.runs[0].localeIdentifier == UInt16.max)
    }

    @Test func rejectsUnexpectedTokenEvenWhenFollowingBytesLookLikeText() throws {
        var data = payload([(Data("Visible".utf8), 1033, 0, 0)])
        put16(99, &data, 36)
        #expect(throws: LegacyContentError.unsupportedRunStructure(offset: 136)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    @Test func rejectsCharacterCountMismatch() throws {
        var data = payload([(Data("Example".utf8), 1033, 0, 0)])
        put32(8, &data, 16)
        put32(9, &data, 32)
        #expect(throws: LegacyContentError.declaredExtentMismatch(scope: "párrafo", offset: 120, expected: 9, actual: 8)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    @Test func checksLengthBeforeReadingTextOrTrailingControl() throws {
        var data = payload([(Data("Short".utf8), 1033, 0, 0)])
        put16(UInt16(Int16.max), &data, 42)
        #expect(throws: LegacyContentError.invalidRange(offset: 147)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    @Test func preservesTrailingStyleIndexWithoutGuessingFormatting() throws {
        let data = payload([(Data("Example".utf8), 1033, 0, 2)])
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.runs.first?.trailingControl == 2)
    }

    @Test func preservesPageZeroCodeUnitsWithoutStrippingInternalControls() throws {
        let data = payload([(Data([0x41, 0x01, 0x42]), 1033, 0, 0)])
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "A\u{0001}B")
        #expect(result.plainText.utf16.count == 3)
    }

    @Test func indexesBothFramingModesAndReportsCompressedReaderLimit() throws {
        let body = payload([(Data("Synthetic".utf8), 1033, 0, 0)])
        var tart = Data(repeating: 0, count: 6)
        put32(UInt32(body.count), &tart, 2)
        tart.append(body)
        var compressedHeader = Data(repeating: 0, count: 12)
        put16(1, &compressedHeader, 0)
        put16(3, &compressedHeader, 2)
        put32(100, &compressedHeader, 4)
        put32(4, &compressedHeader, 8)
        tart.append(compressedHeader)
        tart.append(Data([0x10, 0x20, 0x30, 0x40]))
        try withFile(lsf(tart: tart)) { url in
            let index = try LegacyContentReader.inspectSections(lsfURL: url)
            #expect(index.sections.count == 2)
            #expect(index.sections[0].mode == 0)
            #expect(index.sections[1].mode == 1)
            #expect(index.sections[1].decodedLength == 100)
            let content = try LegacyContentReader.readSection(lsfURL: url, ordinal: 0)
            #expect(content.plainText == "Synthetic")
            #expect(throws: LegacyContentError.compressedSectionUnsupported(codecWord: 3)) {
                try LegacyContentReader.readSection(lsfURL: url, ordinal: 1)
            }
        }
    }

    @Test func rejectsFramingThatExtendsPastTart() throws {
        var tart = Data(repeating: 0, count: 10)
        put32(UInt32.max, &tart, 2)
        try withFile(lsf(tart: tart)) { url in
            #expect(throws: LegacyContentError.invalidRange(offset: 88)) {
                try LegacyContentReader.inspectSections(lsfURL: url)
            }
        }
    }

    @Test func decodesPublishedPKWAREReferenceSample() throws {
        let bytes = Data([0x00, 0x04, 0x82, 0x24, 0x25, 0x8f, 0x80, 0x7f])
        let decoded = try LegacyContentReader.decompressDCL(bytes, expectedLength: 13)
        #expect(String(decoding: decoded, as: UTF8.self) == "AIAIAIAIAIAIA")
    }

    @Test func decompressionDoesNotReturnPartialOutputOnOverflow() throws {
        let bytes = Data([0x00, 0x04, 0x82, 0x24, 0x25, 0x8f, 0x80, 0x7f])
        #expect(throws: LegacyContentError.decompressionFailed(1)) {
            try LegacyContentReader.decompressDCL(bytes, expectedLength: 12)
        }
    }

    @Test func rejectsDeclaredDecodedLengthThatDoesNotMatchCodec() throws {
        let bytes = Data([0x00, 0x04, 0x82, 0x24, 0x25, 0x8f, 0x80, 0x7f])
        #expect(throws: LegacyContentError.decompressedLengthMismatch(expected: 14, actual: 13)) {
            try LegacyContentReader.decompressDCL(bytes, expectedLength: 14)
        }
    }

    @Test func readsAnEntireSyntheticCompressedLSFSection() throws {
        let body = payload([(Data("Our synthetic document".utf8), 1033, 0, 0)])
        let compressed = literalDCL(body)
        var tart = Data(repeating: 0, count: 12)
        put16(1, &tart, 0)
        put32(UInt32(body.count), &tart, 4)
        put32(UInt32(compressed.count), &tart, 8)
        tart.append(compressed)
        try withFile(lsf(tart: tart)) { url in
            let result = try LegacyContentReader.readSection(lsfURL: url, ordinal: 0)
            #expect(result.plainText == "Our synthetic document")
            #expect(result.runs.first?.fileOffset == nil)
            #expect(result.runs.first?.decodedOffset == 36)
        }
    }

    @Test func preservesParagraphBoundariesAndCountsTheirSeparators() throws {
        let first = payload([(Data("First".utf8), 1033, 0, 0)])
        let second = payload([(Data("Second".utf8), 1033, 0, 0)])
        var data = first + second.dropFirst(20)
        put16(2, &data, 12)
        put32(12, &data, 16)
        put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "First\nSecond")
        #expect(result.paragraphs.count == 2)
        #expect(result.paragraphs[1].characterOffset == 6)
    }

    @Test func readsUnicodeUnitsAndValidatesSurrogatePairs() throws {
        var data = payload([(Data("ABC".utf8), 1033, 0, 0)])
        data[46] = 0xf0
        data.replaceSubrange(47..<50, with: Data([0x49, 0x6c, 0x3d, 0xd8, 0x00, 0xde]))
        put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "汉😀")
        #expect(result.expectedCharacterCount == 3)
    }

    @Test func rejectsMalformedUnicodeInsteadOfRepairingBookText() throws {
        var data = payload([(Data("A".utf8), 1033, 0, 0)])
        data[46] = 0xf0
        data.replaceSubrange(47..<48, with: Data([0x3d, 0xd8]))
        put32(UInt32(data.count), &data, 0)
        #expect(throws: LegacyContentError.unsupportedRunStructure(offset: 136)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    @Test func preservesReferenceAnchorWithoutCountingItsLabelAsText() throws {
        let original = payload([(Data("Text".utf8), 1033, 0, 0)])
        var anchor = Data(repeating: 0, count: 8)
        put16(81, &anchor, 0)
        put16(128, &anchor, 2)
        put16(2, &anchor, 4)
        put16(5, &anchor, 6)
        anchor.append(Data("Ref 1".utf8))
        var data = original.prefix(36) + anchor + original.dropFirst(36)
        put16(2, &data, 24)
        put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "Text")
        #expect(result.anchors.count == 1)
        #expect(result.anchors[0].reference == "Ref 1")
        #expect(result.anchors[0].characterOffset == 0)
    }

    @Test func namedGraphicPreservesWireFieldsAndItsSingleLogicalPosition() throws {
        let original = payload([(Data("After".utf8), 1033, 0, 0)])
        var graphic = Data([0x61, 0, 0, 0, 0, 0, 8, 0])
        graphic.append(Data("!map.bmp".utf8))
        var data = original.prefix(36) + graphic + original.dropFirst(36)
        put16(2, &data, 24); put32(6, &data, 16); put32(7, &data, 32); put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "\u{fffc}After")
        #expect(result.runs[0].characterOffset == 1)
        let image = try #require(result.graphics.first)
        #expect(image.reference == "!map.bmp" && image.assetName == "map.bmp")
        #expect(image.characterWidth == 1 && image.objectCharacterOffset == 0)
        #expect(image.decodedOffset == 36 && image.fileOffset == 136)
        #expect(image.rawHeaderHex == graphic.map { String(format: "%02x", $0) }.joined())
    }

    @Test func graphicSoftBreakAndAttributesRemainSeparateFromTheImageUnit() throws {
        let original = payload([(Data("End".utf8), 1033, 0, 0)])
        let reference = "[Percent=50 NoHotSpots]!map.bmp"
        var graphic = Data([0x61, 0, 0x20, 0, 3, 0])
        graphic.append(Data("abc".utf8)); graphic.append(Data([UInt8(reference.utf8.count), 0])); graphic.append(Data(reference.utf8))
        var data = original.prefix(36) + graphic + original.dropFirst(36)
        put16(2, &data, 24); put32(5, &data, 16); put32(6, &data, 32); put32(UInt32(data.count), &data, 0)
        let content = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(content.plainText == "\u{2028}\u{fffc}End")
        #expect(content.graphics[0].attribute == "abc" && content.graphics[0].hasLeadingSoftBreak)
        #expect(content.graphics[0].objectCharacterOffset == 1 && content.graphics[0].assetName == "map.bmp")
        #expect(content.runs[0].characterOffset == 2)
    }

    @Test func embeddedExtendedAndTruncatedGraphicsDoNotProducePartialSuccessfulText() throws {
        let original = payload([(Data("End".utf8), 1033, 0, 0)])
        for graphic in [Data([0x61, 0, 0, 0, 0, 0, 0, 0]), Data([0x61, 0, 0, 0, 0x0d, 0xf0]),
                        Data([0x61, 0, 0, 0, 0, 0, 0xff, 0xff])] {
            var data = original.prefix(36) + graphic + original.dropFirst(36)
            put16(2, &data, 24); put32(UInt32(data.count), &data, 0)
            #expect(throws: (any Error).self) { try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count)) }
        }
    }

    @Test func graphicInCompressedSectionDoesNotInventAPhysicalOffset() throws {
        var body = payload([(Data("End".utf8), 1033, 0, 0)])
        let graphic = Data([0x61, 0, 0, 0, 0, 0, 6, 0]) + Data("!a.bmp".utf8)
        body = body.prefix(36) + graphic + body.dropFirst(36)
        put16(2, &body, 24); put32(4, &body, 16); put32(5, &body, 32); put32(UInt32(body.count), &body, 0)
        let compressed = literalDCL(body)
        var tart = Data(repeating: 0, count: 12)
        put16(1, &tart, 0); put32(UInt32(body.count), &tart, 4); put32(UInt32(compressed.count), &tart, 8); tart.append(compressed)
        try withFile(lsf(tart: tart)) { url in
            let content = try LegacyContentReader.readSection(lsfURL: url, ordinal: 0)
            #expect(content.graphics[0].fileOffset == nil && content.graphics[0].decodedOffset == 36)
        }
    }

    @Test func decodesVerifiedTabRunAndPreservesItsSourceFields() throws {
        let original = payload([(Data("ABC".utf8), 1033, 0, 0)])
        var object = Data(repeating: 0, count: 6)
        put16(33, &object, 0)
        var data = original.prefix(36) + object + original.dropFirst(36)
        put16(2, &data, 24)
        put32(4, &data, 16)
        put32(5, &data, 32)
        put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "\tABC")
        #expect(result.expectedCharacterCount == 4)
        #expect(result.markers.first?.rawHeaderHex == "210000000000")
        #expect(result.markers.first?.characterWidth == 1)
        #expect(result.markers.first?.kind == .tab)
        #expect(result.markers.first?.replacementText == "\t")
        #expect(result.markers.first?.fileOffset == 136)
        #expect(result.runs.first?.characterOffset == 1)
        #expect(!result.warnings.isEmpty)
    }

    @Test func decodesTheNativeImplicitSoftBreakWithoutChangingStoredRunText() throws {
        var data = payload([(Data("A".utf8), 1033, 0, 4), (Data("B".utf8), 1033, 0x20, 9)])
        put32(3, &data, 16)
        put32(4, &data, 32)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "A\u{2028}B")
        #expect(result.plainText.utf16.count == 3)
        #expect(result.runs[1].text == "B")
        #expect(result.runs[1].sourceRunFlags == 0x20)
        #expect(result.runs[1].styleIdentifier == 9)
        #expect(result.runs[1].textEncodingFlags == 0)
        #expect(result.runs[1].logicalText == "\u{2028}B")
        #expect(result.runs[1].logicalCharacterCount == 2)
        #expect(result.runs[1].characterOffset == 1)
        #expect(result.runs[1].storedTextCharacterOffset == 2)
        // An ordinary encoding flag 0x20 does not create an implicit prefix.
        var storedControl = payload([(Data([11]), 1033, 0, 0)])
        storedControl[46] = 0x20
        let preserved = try LegacyContentReader.decodeSimpleLatinRuns(storedControl, section: section(length: storedControl.count))
        #expect(preserved.plainText == "\u{200b}")
        #expect(!preserved.runs[0].hasLeadingSoftBreak)
    }

    @Test func supportsOrdinaryAttributesAndRejectsMalformedExtendedHeaders() throws {
        let original = payload([(Data("X".utf8), 1033, 0x20, 3)])
        var data = Data(original.prefix(42)) + Data("link".utf8) + original.dropFirst(42)
        put16(4, &data, 40)
        put32(2, &data, 16)
        put32(3, &data, 32)
        put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "\u{2028}X")
        #expect(result.runs[0].attribute == "link")
        #expect(result.runs[0].styleIdentifier == 3)
        put16(0xf00d, &data, 40)
        #expect(throws: LegacyContentError.invalidRange(offset: 146)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    @Test func decodesCompactCharRunsWithTheirByteStyleAndUnicodePage() throws {
        let original = payload([(Data("A".utf8), 1033, 0, 0)])
        let compact = Data([0x12, 0, 2, 0, 0x03, 0xb1, 0xb2, 0xc8])
        var data = Data(original.prefix(36)) + compact
        put32(2, &data, 16)
        put32(3, &data, 32)
        put32(UInt32(data.count), &data, 0)
        let decoded = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(decoded.plainText == "αβ")
        #expect(decoded.runs[0].controlToken == 0x12)
        #expect(decoded.runs[0].localeIdentifier == 1033)
        #expect(decoded.runs[0].sourceRunFlags == 0)
        #expect(decoded.runs[0].styleIdentifier == 200)
        #expect(decoded.runs[0].attribute == nil)
        #expect(decoded.runs[0].textEncodingPage == 3)
        var unicode = Data(original.prefix(36)) + Data([0x12, 0, 2, 0, 0xf0, 0x3e, 0xd8, 0x89, 0xdd, 7])
        put32(2, &unicode, 16)
        put32(3, &unicode, 32)
        put32(UInt32(unicode.count), &unicode, 0)
        #expect(try LegacyContentReader.decodeSimpleLatinRuns(unicode, section: section(length: unicode.count)).plainText == "🦉")
        unicode.removeLast()
        put32(UInt32(unicode.count), &unicode, 0)
        #expect(throws: LegacyContentError.invalidRange(offset: 141)) {
            try LegacyContentReader.decodeSimpleLatinRuns(unicode, section: section(length: unicode.count))
        }
    }

    @Test func decodesCompressedUnicodePagesAndDistinguishesTheirZeroByte() throws {
        var data = payload([(Data([0x14, 0x19, 0x0b, 0]), 1033, 0, 0)])
        data[46] = 0x20
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "—’\u{200b}\u{0000}")
        #expect(result.runs[0].textEncodingPage == 0x20)
        #expect(!result.runs[0].isStoredUTF16)
        #expect(result.plainText.utf16.count == 4)
        var latin = payload([(Data([0x80, 0x92, 0xe1]), 1033, 0, 0)])
        let pageZero = try LegacyContentReader.decodeSimpleLatinRuns(latin, section: section(length: latin.count))
        #expect(pageZero.plainText == "\u{0080}\u{0092}á")
        latin[46] = 0xd8
        #expect(throws: LegacyContentError.unsupportedRunStructure(offset: 136)) {
            try LegacyContentReader.decodeSimpleLatinRuns(latin, section: section(length: latin.count))
        }
    }

    @Test func requiresTheDeclaredLogicalWidthForAnImplicitSoftBreak() throws {
        let data = payload([(Data("Text".utf8), 1033, 0x20, 0)])
        #expect(throws: LegacyContentError.declaredExtentMismatch(scope: "párrafo", offset: 120, expected: 5, actual: 6)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    @Test func preservesEmptyParagraphsAndTheirDeclaredSeparators() throws {
        let original = payload([(Data("A".utf8), 1033, 0, 0)])
        var empty = Data(repeating: 0, count: 16)
        put16(1, &empty, 0)
        put16(1, &empty, 2)
        put32(1, &empty, 12)
        var data = Data(original.prefix(20)) + empty + original.dropFirst(20)
        put16(2, &data, 12)
        put32(2, &data, 16)
        put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "\nA")
        #expect(result.paragraphs.map(\.declaredCharacterCount) == [1, 2])
        #expect(result.runs[0].characterOffset == 1)
        #expect(result.expectedCharacterCount == 2)
        var onlyEmpty = Data(original.prefix(20)) + empty
        put32(0, &onlyEmpty, 16)
        put32(UInt32(onlyEmpty.count), &onlyEmpty, 0)
        #expect(try LegacyContentReader.decodeSimpleLatinRuns(onlyEmpty, section: section(length: onlyEmpty.count)).plainText == "")
    }

    @Test func acceptsAParagraphContainingOnlyTheShortestVerifiedTabRun() throws {
        let original = payload([(Data("A".utf8), 1033, 0, 0)])
        var data = Data(original.prefix(36)) + Data([33, 0, 0, 0, 0, 0])
        put32(1, &data, 16)
        put32(2, &data, 32)
        put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == "\t")
        #expect(result.runs.isEmpty)
        #expect(result.markers.count == 1)
        #expect(result.expectedCharacterCount == 1)
    }

    @Test func rejectsTabRunSerializedValuesOutsideTheValidatedShape() throws {
        let original = payload([(Data("ABC".utf8), 1033, 0, 0)])
        var object = Data(repeating: 0, count: 6)
        put16(33, &object, 0)
        put32(1, &object, 2)
        var data = original.prefix(36) + object + original.dropFirst(36)
        put16(2, &data, 24)
        put32(UInt32(data.count), &data, 0)
        #expect(throws: LegacyContentError.unsupportedRunStructure(offset: 136)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    @Test func readsSpecialRunFieldsAndKeepsFollowingReferenceCoordinates() throws {
        let original = payload([(Data("ABC".utf8), 1033, 0, 0)])
        let special = Data([0x71, 0, 0, 0, 1, 0, 0, 0])
        var anchor = Data([0x51, 0, 0x80, 0, 2, 0, 5, 0])
        anchor.append(Data("Ref 1".utf8))
        var data = Data(original.prefix(36)) + special + anchor + original.dropFirst(36)
        put16(3, &data, 24)
        put32(4, &data, 16); put32(5, &data, 32); put32(UInt32(data.count), &data, 0)
        let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        #expect(result.plainText == " ABC")
        #expect(result.markers[0].kind == .special)
        #expect(result.markers[0].sourceRunFlags == 0)
        #expect(result.markers[0].value == 1)
        #expect(result.markers[0].characterWidth == 1)
        #expect(result.markers[0].rawHeaderHex == "7100000001000000")
        #expect(result.markers[0].decodedOffset == 36 && result.markers[0].fileOffset == 136)
        #expect(result.anchors[0].characterOffset == 1)
        #expect(result.runs[0].characterOffset == 1)
        #expect(result.warnings.contains { $0.contains("CSpecialRun") })
        #expect(!result.warnings.contains { $0.contains("CTabRun") })
    }

    @Test func specialRunZeroWidthAndBitValuesPreserveTheExactSerializedValue() throws {
        let cases: [(UInt32, String)] = [(0, ""), (1, " "), (2, ""), (3, " "), (.max, " ")]
        for (value, expected) in cases {
            let original = payload([(Data("X".utf8), 1033, 0, 0)])
            var special = Data([0x71, 0, 0, 0, 0, 0, 0, 0]); put32(value, &special, 4)
            var data = Data(original.prefix(36)) + special + original.dropFirst(36)
            put16(2, &data, 24)
            put32(UInt32(expected.utf16.count + 1), &data, 16)
            put32(UInt32(expected.utf16.count + 2), &data, 32)
            put32(UInt32(data.count), &data, 0)
            let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
            #expect(result.plainText == expected + "X")
            #expect(result.markers[0].value == value)
            #expect(result.markers[0].replacementText == expected)
            #expect(result.markers[0].characterWidth == expected.utf16.count)
            #expect(result.runs[0].characterOffset == expected.utf16.count)
        }
    }

    @Test func specialRunSoftBreakAndVisibilityFlagsRemainDistinctFromLogicalProjection() throws {
        let cases: [(UInt16, String)] = [(0x20, "\u{2028} "), (0x80, " "), (0xA0, "\u{2028} "), (0x2000, " ")]
        for (flags, expected) in cases {
            let original = payload([(Data("A".utf8), 1033, 0, 0)])
            var special = Data([0x71, 0, 0, 0, 1, 0, 0, 0]); put16(flags, &special, 2)
            var data = Data(original.prefix(36)) + special
            put32(UInt32(expected.utf16.count), &data, 16)
            put32(UInt32(expected.utf16.count + 1), &data, 32)
            put32(UInt32(data.count), &data, 0)
            let result = try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
            #expect(result.plainText == expected)
            #expect(result.runs.isEmpty)
            #expect(result.markers[0].sourceRunFlags == flags)
            #expect(result.markers[0].logicalText == expected)
            #expect(result.markers[0].characterWidth == expected.utf16.count)
            #expect(result.warnings.contains { $0.contains("visibilidad") })
        }
    }

    @Test func specialRunTruncationAndWrongDeclaredCountsNeverReturnPartialSuccess() throws {
        let original = payload([(Data("A".utf8), 1033, 0, 0)])
        let special = Data([0x71, 0, 0, 0, 1, 0, 0, 0])
        for length in [6, 7] {
            var data = Data(original.prefix(36)) + special.prefix(length)
            put32(UInt32(data.count), &data, 0)
            #expect(throws: LegacyContentError.invalidRange(offset: 136)) {
                try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
            }
        }
        var data = Data(original.prefix(36)) + special
        put32(0, &data, 16); put32(1, &data, 32); put32(UInt32(data.count), &data, 0)
        #expect(throws: LegacyContentError.declaredExtentMismatch(scope: "párrafo", offset: 120, expected: 1, actual: 2)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    @Test func specialRunsInsideCompressedSectionsKeepDecodedOffsetsOnly() throws {
        let original = payload([(Data("ABC".utf8), 1033, 0, 0)])
        var body = Data(original.prefix(36)) + Data([0x71, 0, 0, 0, 1, 0, 0, 0]) + original.dropFirst(36)
        put16(2, &body, 24); put32(4, &body, 16); put32(5, &body, 32); put32(UInt32(body.count), &body, 0)
        let compressed = literalDCL(body)
        var tart = Data(repeating: 0, count: 12)
        put16(1, &tart, 0); put32(UInt32(body.count), &tart, 4); put32(UInt32(compressed.count), &tart, 8)
        tart.append(compressed)
        try withFile(lsf(tart: tart)) { url in
            let result = try LegacyContentReader.readSection(lsfURL: url, ordinal: 0)
            #expect(result.plainText == " ABC")
            #expect(result.markers[0].fileOffset == nil)
            #expect(result.markers[0].decodedOffset == 36)
            #expect(result.runs[0].characterOffset == 1)
        }
    }

    @Test func doesNotAlterDeclaredCountsToAccommodateAnObject() throws {
        let original = payload([(Data("ABC".utf8), 1033, 0, 0)])
        var object = Data(repeating: 0, count: 6)
        put16(33, &object, 0)
        var data = original.prefix(36) + object + original.dropFirst(36)
        put16(2, &data, 24)
        put32(UInt32(data.count), &data, 0)
        #expect(throws: LegacyContentError.declaredExtentMismatch(scope: "párrafo", offset: 120, expected: 4, actual: 5)) {
            try LegacyContentReader.decodeSimpleLatinRuns(data, section: section(length: data.count))
        }
    }

    // Own literal-only fixture encoder from public DCL bit-stream description:
    // literal flag 0 + eight byte bits; final length519 has code15 (seven zeros)
    // plus extra255, preceded by length/distance flag1. No commercial data.
    private func literalDCL(_ body: Data) -> Data {
        var output = Data([0, 4])
        var buffer: UInt32 = 0
        var bits = 0
        func write(_ value: UInt32, count: Int) {
            buffer |= value << UInt32(bits)
            bits += count
            while bits >= 8 {
                output.append(UInt8(buffer & 0xff))
                buffer >>= 8
                bits -= 8
            }
        }
        for byte in body {
            write(0, count: 1)
            write(UInt32(byte), count: 8)
        }
        write(1, count: 1)
        write(0, count: 7)
        write(255, count: 8)
        if bits > 0 { output.append(UInt8(buffer & 0xff)) }
        return output
    }

    private func section(length: Int) -> LegacySectionDescriptor {
        LegacySectionDescriptor(ordinal: 0, headerOffset: 94, payloadOffset: 100,
                                storedLength: UInt32(length), decodedLength: UInt32(length), mode: 0, codecWord: nil)
    }

    private func payload(_ runs: [(Data, UInt16, UInt32, UInt16)]) -> Data {
        var data = Data(repeating: 0, count: 36)
        put16(17, &data, 4)
        put32(1, &data, 6)
        put16(1, &data, 10)
        put16(1, &data, 12)
        let characters = UInt32(runs.reduce(0) { $0 + $1.0.count })
        put32(characters, &data, 16)
        put16(1, &data, 20)
        put16(1, &data, 22)
        put16(UInt16(runs.count), &data, 24)
        put32(10_000, &data, 26)
        put32(characters + 1, &data, 32)
        for (text, locale, style, trailing) in runs {
            var header = Data(repeating: 0, count: 11)
            put16(17, &header, 0)
            put32(style, &header, 2)
            put16(UInt16(text.count), &header, 6)
            put16(locale, &header, 8)
            data.append(header)
            data.append(text)
            data.append(Data([UInt8(trailing & 0xff), UInt8(trailing >> 8)]))
        }
        put32(UInt32(data.count), &data, 0)
        return data
    }

    private func lsf(tart: Data) -> Data {
        var data = Data(repeating: 0, count: 44 + 36 + 8)
        data.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        data.replaceSubrange(8..<12, with: Data("GTTL".utf8))
        data.replaceSubrange(36..<40, with: Data("pcr ".utf8))
        put32(36, &data, 40)
        data.replaceSubrange(44..<48, with: Data("LSFF".utf8))
        data.replaceSubrange(48..<52, with: Data("GTTL".utf8))
        data.replaceSubrange(62..<66, with: Data("tart".utf8))
        put32(UInt32(tart.count), &data, 70)
        put32(88, &data, 74)
        data.replaceSubrange(80..<84, with: Data("tart".utf8))
        put32(UInt32(tart.count), &data, 84)
        data.append(tart)
        put32(UInt32(data.count - 8), &data, 4)
        return data
    }

    private func withFile(_ data: Data, body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".LSF")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func put16(_ value: UInt16, _ data: inout Data, _ index: Int) {
        data[index] = UInt8(value & 0xff)
        data[index + 1] = UInt8(value >> 8)
    }

    private func put32(_ value: UInt32, _ data: inout Data, _ index: Int) {
        for shift in 0..<4 { data[index + shift] = UInt8((value >> UInt32(shift * 8)) & 0xff) }
    }
}
