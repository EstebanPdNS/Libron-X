import Foundation
import Testing
@testable import LibronixCore

struct LegacyStructuredAnchorTests {
    @Test func pageAnchorPreservesTypedFieldsAndUnicodeTextBoundary() throws {
        let page = structured(Data([0x50]), [6])
        var textual = words([0x51, 128, 2, 6]); textual.append(Data("Ge 1:1".utf8))
        let data = document([page, text("漢😀"), textual, text("Q")], characters: 4)
        let result = try decode(data)
        #expect(result.plainText == "漢😀Q")
        #expect(result.runs[0].decodedOffset == 51)
        #expect(result.runs[0].logicalCharacterCount == 3)
        #expect(result.anchors[0].reference == nil)
        #expect(result.anchors[0].dataTypeCode == 8)
        #expect(result.anchors[0].flags == 128)
        #expect(result.anchors[0].characterOffset == 0)
        let reference = try #require(result.anchors[0].structuredReference)
        #expect(reference.schemeBytes == Data([0x50]))
        #expect(reference.componentBits == [6])
        #expect(reference.knownScheme == .page)
        #expect(result.anchors[1].reference == "Ge 1:1")
        #expect(result.anchors[1].structuredReference == nil)
        #expect(result.anchors[1].characterOffset == 3)
        #expect(result.runs[1].characterOffset == 3)
    }

    @Test func unknownByteSchemesAndComponentBitsRemainUnresolved() throws {
        for scheme in [Data("α".utf8), Data("p".utf8), Data("Page".utf8), Data([0x50, 0])] {
            let data = document([structured(scheme, [UInt32.max]), text("Q")], characters: 1)
            let result = try decode(data)
            let reference = try #require(result.anchors[0].structuredReference)
            #expect(reference.schemeBytes == scheme)
            #expect(reference.componentBits == [UInt32.max])
            #expect(reference.knownScheme == nil)
            #expect(result.anchors[0].reference == nil)
            #expect(result.plainText == "Q")
        }
        let wrongDimensions = try decode(document([structured(Data([0x50]), [1, 2]), text("Q")], characters: 1))
        #expect(wrongDimensions.anchors[0].structuredReference?.knownScheme == nil)
        #expect(wrongDimensions.anchors[0].structuredReference?.componentBits == [1, 2])
    }

    @Test func maximumFramingLimitsKeepAllComponentsAndTheNextRun() throws {
        let scheme = Data(repeating: 0x51, count: 20)
        let components = (0..<64).map(UInt32.init)
        let result = try decode(document([structured(scheme, components), text("Q")], characters: 1))
        #expect(result.anchors[0].structuredReference?.schemeBytes == scheme)
        #expect(result.anchors[0].structuredReference?.componentBits == components)
        #expect(result.runs[0].decodedOffset == 322)
        #expect(result.anchors[0].reference == nil)
        #expect(result.plainText == "Q")
    }

    @Test func invalidSchemeLengthsFailBeforeReadingSchemeOrComponents() throws {
        for length: UInt16 in [0, UInt16.max, 21] {
            let bad = words([0x51, 128, 8, length]) + Data(repeating: 0x51, count: 21)
            let data = document([bad], characters: 0)
            #expect(throws: LegacyContentError.unsupportedRunStructure(offset: 136)) { try decode(data) }
        }
    }

    @Test func invalidComponentCountsFailBeforeAllocation() throws {
        for count: UInt16 in [0, UInt16.max, 65] {
            let bad = words([0x51, 128, 8, 1]) + Data([0x50]) + words([count])
            let data = document([bad], characters: 0)
            #expect(throws: LegacyContentError.unsupportedRunStructure(offset: 136)) { try decode(data) }
        }
    }

    @Test func truncatedSchemeAndDwordFailAtTheirFieldBoundaries() throws {
        let scheme = words([0x51, 128, 8, 4]) + Data([0x51])
        #expect(throws: LegacyContentError.invalidRange(offset: 144)) {
            try decode(document([scheme], characters: 0))
        }
        let component = words([0x51, 128, 8, 1]) + Data([0x50]) + words([1]) + Data([6, 0, 0])
        #expect(throws: LegacyContentError.invalidRange(offset: 147)) {
            try decode(document([component], characters: 0))
        }
    }

    @Test func oldTextualAnchorJSONStillDecodesWithoutStructuredFields() throws {
        let json = Data(#"{"reference":"Ge 1:1","flags":128,"dataTypeCode":2,"characterOffset":0,"decodedOffset":36}"#.utf8)
        let reference = try JSONDecoder().decode(LegacyReferenceAnchor.self, from: json)
        #expect(reference.reference == "Ge 1:1")
        #expect(reference.structuredReference == nil)
    }

    @Test func structuredAnchorRoundTripDoesNotInventTextualReference() throws {
        let original = LegacyReferenceAnchor(reference: nil, flags: 128, dataTypeCode: 8, characterOffset: 3, decodedOffset: 36,
            structuredReference: LegacyStructuredReference(schemeBytes: Data([0x50]), componentBits: [UInt32.max]))
        let restored = try JSONDecoder().decode(LegacyReferenceAnchor.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.reference == nil)
        #expect(restored.structuredReference?.componentBits == [UInt32.max])
    }

    @Test func pageAnchorDoesNotTruncateOrCreateABibleVerse() throws {
        let anchors = [
            LegacyReferenceAnchor(reference: "Ge 1:1", flags: 128, dataTypeCode: 2, characterOffset: 0, decodedOffset: 36),
            LegacyReferenceAnchor(reference: nil, flags: 128, dataTypeCode: 8, characterOffset: 1, decodedOffset: 51,
                structuredReference: LegacyStructuredReference(schemeBytes: Data([0x50]), componentBits: [6]))
        ]
        let verses = try BibleVerseText.intervals(text: "QR", anchors: anchors)
        #expect(verses.count == 1)
        #expect(verses[0].reference == "Ge 1:1")
        #expect(verses[0].range == SearchTextRange(location: 0, length: 2))
    }

    private func structured(_ scheme: Data, _ components: [UInt32]) -> Data {
        var result = words([0x51, 128, 8, UInt16(scheme.count)])
        result.append(scheme); result.append(words([UInt16(components.count)]))
        for component in components { result.append(integer(component)) }
        return result
    }

    private func text(_ value: String) -> Data {
        let units = Array(value.utf16)
        var result = words([0x11, 0, 0, UInt16(units.count), 1033])
        result.append(0xf0); result.append(words(units)); result.append(words([0]))
        return result
    }

    private func document(_ runs: [Data], characters: UInt16) -> Data {
        var result = Data(repeating: 0, count: 20)
        result.replaceSubrange(4..<6, with: words([17]))
        result.replaceSubrange(6..<10, with: integer(1))
        result.replaceSubrange(10..<14, with: words([1, 1]))
        result.replaceSubrange(16..<20, with: integer(UInt32(characters)))
        result.append(words([1, 1, UInt16(runs.count), 0, 0, 0, characters + 1, 0]))
        for run in runs { result.append(run) }
        result.replaceSubrange(0..<4, with: integer(UInt32(result.count)))
        return result
    }

    private func words(_ values: [UInt16]) -> Data {
        Data(values.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
    }

    private func integer(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) })
    }

    private func decode(_ data: Data) throws -> LegacySectionContent {
        let descriptor = LegacySectionDescriptor(ordinal: 0, headerOffset: 94, payloadOffset: 100,
            storedLength: UInt32(data.count), decodedLength: UInt32(data.count), mode: 0, codecWord: nil)
        return try LegacyContentReader.decodeSimpleLatinRuns(data, section: descriptor)
    }
}
