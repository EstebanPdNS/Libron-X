import Foundation
import Testing
@testable import LibronixCore

struct LegacyEmptyRunTests {
    @Test func emptySoftBreakPreservesStyleAndFollowingParagraphBoundary() throws {
        let first = paragraph([empty(flags: 0x20, style: 10009)], characters: 1)
        let second = paragraph([normal("A")], characters: 1)
        let data = document([first, second], characters: 3)
        let result = try decode(data)
        #expect(result.plainText == "\u{2028}\nA")
        #expect(result.paragraphs[1].decodedOffset == 48)
        #expect(result.paragraphs[1].characterOffset == 2)
        #expect(result.runs[0].text.isEmpty)
        #expect(result.runs[0].styleIdentifier == 10009)
        #expect(result.runs[0].serializedTextEncodingByte == nil)
        #expect(result.runs[0].textEncodingPage == nil)
        #expect(!result.runs[0].isStoredUTF16)
        #expect(result.runs[0].logicalCharacterCount == 1)
    }

    @Test func emptyRunKeepsAdjacentAnchorAndTextCoordinates() throws {
        var anchor = words([0x51, 128, 2, 3])
        anchor.append(Data("own".utf8))
        let data = document([paragraph([empty(flags: 0x20, style: 9), anchor, normal("B")], characters: 2)], characters: 2)
        let result = try decode(data)
        #expect(result.plainText == "\u{2028}B")
        #expect(result.anchors[0].reference == "own")
        #expect(result.anchors[0].decodedOffset == 48)
        #expect(result.anchors[0].characterOffset == 1)
        #expect(result.runs[1].decodedOffset == 59)
        #expect(result.runs[1].characterOffset == 1)
        #expect(result.runs[1].serializedTextEncodingByte == 0)
    }

    @Test func styleLowByteCannotBecomeAnEncodingPage() throws {
        let data = document([paragraph([empty(flags: 0, style: 0xf025), normal("C")], characters: 1)], characters: 1)
        let result = try decode(data)
        #expect(result.plainText == "C")
        #expect(result.runs[0].styleIdentifier == 0xf025)
        #expect(result.runs[0].logicalCharacterCount == 0)
        #expect(result.runs[0].serializedTextEncodingByte == nil)
        #expect(result.runs[1].decodedOffset == 48)
        #expect(result.runs[1].characterOffset == 0)
    }

    @Test func emptyStoredTextCanFormACompleteEmptyParagraph() throws {
        let data = document([paragraph([empty(flags: 0, style: 3)], characters: 0)], characters: 0)
        let result = try decode(data)
        #expect(result.plainText.isEmpty)
        #expect(result.expectedCharacterCount == 0)
        #expect(result.paragraphs[0].declaredCharacterCount == 1)
        #expect(result.runs[0].logicalCharacterCount == 0)
    }

    @Test func missingEmptyRunStyleFailsAtItsActualBoundary() throws {
        for missingBytes in 1...2 {
            var run = empty(flags: 0, style: 3)
            run.removeLast(missingBytes)
            let data = document([paragraph([run], characters: 0)], characters: 0)
            #expect(throws: LegacyContentError.invalidRange(offset: 146)) {
                try decode(data)
            }
        }
    }

    @Test func negativeStoredLengthStillFailsBeforeStorageRead() throws {
        let run = words([0x11, 0, 0, UInt16.max, 1033, 0])
        let data = document([paragraph([run], characters: 0)], characters: 0)
        #expect(throws: LegacyContentError.unsupportedRunStructure(offset: 136)) {
            try decode(data)
        }
    }

    private func empty(flags: UInt16, style: UInt16) -> Data {
        // No page byte between locale and style for a normal zero-length run.
        words([0x11, flags, 0, 0, 1033, style])
    }

    private func normal(_ text: String) -> Data {
        var run = words([0x11, 0, 0, UInt16(text.utf8.count), 1033])
        run.append(0); run.append(Data(text.utf8)); run.append(words([0]))
        return run
    }

    private func paragraph(_ runs: [Data], characters: UInt16) -> Data {
        var result = words([1, 1, UInt16(runs.count), 0, 0, 0, characters + 1, 0])
        for run in runs { result.append(run) }
        return result
    }

    private func document(_ paragraphs: [Data], characters: UInt32) -> Data {
        var result = Data(repeating: 0, count: 20)
        result.replaceSubrange(4..<6, with: words([17]))
        result.replaceSubrange(6..<10, with: integer(1))
        result.replaceSubrange(10..<14, with: words([1, UInt16(paragraphs.count)]))
        result.replaceSubrange(16..<20, with: integer(characters))
        for paragraph in paragraphs { result.append(paragraph) }
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
