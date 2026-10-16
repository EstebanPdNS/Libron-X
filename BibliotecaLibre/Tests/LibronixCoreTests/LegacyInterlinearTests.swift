import Foundation
import Testing
@testable import LibronixCore

struct LegacyInterlinearTests {
    private func words(_ xs: [UInt16]) -> Data { Data(xs.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }) }
    private func integer(_ x: UInt32) -> Data { words([UInt16(truncatingIfNeeded: x), UInt16(truncatingIfNeeded: x >> 16)]) }
    private func character(_ text: String) -> Data {
        let units = Array(text.utf16)
        return words([0x11,0,0,UInt16(units.count),1033]) + Data([0xf0]) + words(units) + words([0])
    }
    private func unit(token: UInt16 = 0x202, flags: UInt16 = 0, mapping: Bool = false,
                      surface: String = "cat", annotation: String = "γάτα", mask: UInt32 = 3,
                      declared: UInt32? = nil, nested: Data? = nil) -> Data {
        var result = words([token,flags])
        if token == 0x202 { result += words([0, mapping ? 1 : 0]) }
        result += words([2]) + integer(declared ?? UInt32(surface.utf16.count)) + words([9]) + integer(mask)
        if mask & 1 != 0 {
            result += words([1]) + (nested ?? character(surface))
            if mapping { result += words([1,0,3]) }
        }
        if mask & 2 != 0 {
            result += words([1]) + character(annotation)
            if mapping { result += words([2,0,2,2,4]) }
        }
        return result
    }
    private func article(_ run: Data, surface: String) -> Data {
        let body = words([1,1,2,0,0,0,UInt16(surface.utf16.count + 2),0]) + run + character("!")
        return integer(UInt32(20 + body.count)) + words([17]) + integer(1) + words([1,1,0]) + integer(UInt32(surface.utf16.count + 1)) + body
    }
    private func decode(_ data: Data, mode: UInt16 = 0) throws -> LegacySectionContent {
        try LegacyContentReader.decodeSimpleLatinRuns(data, section: .init(ordinal: 0, headerOffset: 94, payloadOffset: 100,
            storedLength: UInt32(data.count), decodedLength: UInt32(data.count), mode: mode, codecWord: mode == 0 ? nil : 0))
    }
    @Test func rowStringsStaySeparateAndFollowingRunsKeepSurfaceCoordinates() throws {
        for token: UInt16 in [0x201,0x202] {
            let content = try decode(article(unit(token: token), surface: "cat"))
            let value = try #require(content.interlinears?.first)
            #expect(content.plainText == "cat!" && content.hasCompatibleFlatTextProjection)
            #expect(value.token == token && value.declaredCharacterCount == 3 && value.sourceField == 9)
            #expect(value.lines.map(\.text) == ["cat","γάτα"])
            #expect(content.runs.map(\.text) == ["cat","!"] && content.runs.map(\.characterOffset) == [0,3])
            #expect(value.lines[1].runs[0].characterOffset == 0)
            #expect(value.decodedOffset == 36 && value.fileOffset == 136)
            #expect(content.paragraphDocuments?.first?.interlinears?.first == value)
            #expect(try JSONDecoder().decode(LegacySectionContent.self, from: JSONEncoder().encode(content)) == content)
        }
    }
    @Test func mappingPairsAndAbsentLinesRemainSourceMetadata() throws {
        let mapped = try decode(article(unit(mapping: true), surface: "cat"))
        let lines = try #require(mapped.interlinears?.first?.lines)
        #expect(lines[0].mappings == [.init(first: 0, second: 3)])
        #expect(lines[1].mappings == [.init(first: 0, second: 2), .init(first: 2, second: 4)])
        let missing = try decode(article(unit(mask: 1), surface: "cat"))
        #expect(missing.interlinears?.first?.lines[1].isSerialized == false)
        #expect(missing.interlinears?.first?.lines[1].text == "")
    }
    @Test func softBreakAndSupplementarySurfaceCharactersUseUTF16WithoutAnnotationOffsets() throws {
        let content = try decode(article(unit(flags: 0x20, surface: "α😀"), surface: "\u{2028}α😀"), mode: 1)
        let value = try #require(content.interlinears?.first)
        #expect(content.plainText == "\u{2028}α😀!" && value.surfaceCharacterOffset == 1)
        #expect(content.runs.map(\.characterOffset) == [1,4])
        #expect(value.fileOffset == nil && value.lines[1].runs[0].fileOffset == nil)
    }
    @Test func malformedLengthsMappingsAndRecursionCannotReturnPartialText() throws {
        #expect(throws: LegacyContentError.self) { try decode(article(unit(declared: 40), surface: "cat")) }
        let valid = article(unit(mapping: true), surface: "cat")
        for count in [39,43,47,51,65,valid.count - 3] {
            var truncated = Data(valid.prefix(count)); truncated.replaceSubrange(0..<4, with: integer(UInt32(count)))
            #expect(throws: LegacyContentError.self) { try decode(truncated) }
        }
        var nested = unit()
        for _ in 0..<10 { nested = unit(nested: nested) }
        #expect(throws: LegacyContentError.contentLimitExceeded) { try decode(article(nested, surface: "cat")) }
        var negative = article(unit(), surface: "cat"); negative.replaceSubrange(44..<46, with: words([UInt16.max]))
        #expect(throws: LegacyContentError.self) { try decode(negative) }
    }
}
