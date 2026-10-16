import Foundation
import Testing
@testable import LibronixCore

struct LegacyInlineLinksTests {
    private func run(_ text: String, offset: Int = 0, attribute: String? = nil, flags: UInt16 = 3,
                     strings: [Data]? = nil) -> LegacyTextRun {
        .init(text: text, controlToken: 0x11, styleValue: UInt32(flags), localeIdentifier: 1033, flags: 0,
              trailingControl: 0, attribute: attribute, characterOffset: offset, fileOffset: nil, decodedOffset: 0,
              extendedAttributes: strings.map { .init(flags: 1, rawData: Data(), strings: $0, values: [], unparsedTail: Data()) })
    }
    private func content(_ text: String, runs: [LegacyTextRun]) -> LegacySectionContent {
        .init(descriptor: .init(ordinal: 4, headerOffset: 0, payloadOffset: 0, storedLength: 0, decodedLength: 0, mode: 0, codecWord: nil),
              plainText: text, runs: runs, expectedCharacterCount: UInt32(text.utf16.count), recognizedFormat: "authored",
              paragraphs: [], anchors: [], markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
    }
    @Test func plainAndExtendedNamesResolveToExactEditionLocalArticles() {
        let body = content("a ñ", runs: [run("a", attribute: "Ge.5"), run("ñ", offset: 2, strings: [Data([0x4e,0x2e,0xf1])])])
        let result = LegacyInlineLinks.resolve(content: body, namedPositions: [
            .init(directoryRow: 0, articleID: 17, label: "Ge.5"), .init(directoryRow: 1, articleID: 900, label: "N.ñ")])
        #expect(result.unresolvedAttributedRuns == 0 && result.links.map(\.sectionOrdinal) == [17,900])
        #expect(result.links.map(\.range) == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
        #expect(result.links.map(\.sourceName) == ["Ge.5","N.ñ"] && body.plainText == "a ñ")
    }
    @Test func implicitSoftBreakStaysOutsideTheLinkAndSurrogatePairsRetainUTF16Ranges() {
        let body = content("\u{2028}😀", runs: [run("😀", attribute: "note", flags: 0x23)])
        let result = LegacyInlineLinks.resolve(content: body, namedPositions: [.init(directoryRow: 0, articleID: 12, label: "note")])
        #expect(result.links.first?.range == NSRange(location: 1, length: 2) && result.links.first?.label == "😀")
    }
    @Test func ambiguousMissingCommandLikeAndMismatchedTextAreNotGuessed() {
        let body = content("abcd", runs: [run("a", attribute: "duplicate"), run("b", offset: 1, attribute: "missing"),
            run("c", offset: 2, attribute: "javascript:alert(1)"), run("x", offset: 3, attribute: "real")])
        let result = LegacyInlineLinks.resolve(content: body, namedPositions: [
            .init(directoryRow: 0, articleID: 1, label: "duplicate"), .init(directoryRow: 1, articleID: 2, label: "duplicate"),
            .init(directoryRow: 2, articleID: 3, label: "real")])
        #expect(result.links.isEmpty && result.unresolvedAttributedRuns == 4)
    }
    @Test func bibleLinksRetainExplicitRangesEditionsAndOneChapterAddresses() throws {
        let source = content("12 He. 11.4", runs: [run("12", attribute: "=rGe 4:12-14(RVR95)"),
            run("He. 11.4", offset: 3, strings: [Data("=rHeb 11:4".utf8)])])
        let result = LegacyInlineLinks.resolve(content: source, namedPositions: [])
        #expect(result.unresolvedAttributedRuns == 0 && result.links.count == 2)
        guard case let .bible(first) = try #require(result.links.first).target else { Issue.record("Expected a Bible target"); return }
        #expect(first.passage.start.key == "ge 4:12" && first.passage.end.key == "ge 4:14" && first.edition == "RVR95")
        #expect(result.links.first?.sectionOrdinal == nil)
        #expect(LegacyBibleLinkReference.parse("=rJud 11")?.passage.start.key == "jud 1:11")
        #expect(LegacyBibleLinkReference.parse("=rLu 11:51")?.passage.start.key == "lk 11:51")
        #expect(LegacyBibleLinkReference.parse("=r1Jo 3:12")?.passage.start.key == "1jn 3:12")
        for invalid in ["=rGe 4:12-2", "=rGe 4", "=rGe 4:1(file:///own)", "=rGe 4:1(RVR95)extra", "jump|res=LLS:1", "=rGe 0:1"] {
            #expect(LegacyBibleLinkReference.parse(invalid) == nil)
        }
    }
    @Test func invalidOffsetsAndEmptyRunsDoNotOverflowOrCreateClickableText() {
        let body = content("a", runs: [run("a", offset: .max, attribute: "note", flags: 0x23),
            run("a", offset: -1, attribute: "note"), run("", attribute: "note")])
        let result = LegacyInlineLinks.resolve(content: body, namedPositions: [.init(directoryRow: 0, articleID: 0, label: "note")])
        #expect(result.links.isEmpty && result.unresolvedAttributedRuns == 3)
    }
}
