import Foundation
import Testing
@testable import LibronixCore

struct BibleReferenceMentionTests {
    private func mentions(_ text: String) throws -> [BibleReferenceMention] { try BibleReferenceMentions.extract(text) }
    @Test func aliasesPunctuationAndOriginalUTF16CoordinatesRemainExact() throws {
        let text = "😀 e\u{301} Véase Jn. 3:16; también John 3.16 y Juan 3,16; Génesis 1:1; Ge\u{301}nesis 1:2."
        let found = try mentions(text)
        #expect(found.map(\.label) == ["Jn. 3:16","John 3.16","Juan 3,16","Génesis 1:1","Ge\u{301}nesis 1:2"])
        #expect(found.prefix(3).allSatisfy { $0.citation.spans[0].lower.book == "jn" })
        for mention in found { #expect((text as NSString).substring(with:mention.range.nsRange) == mention.label) }
        #expect(found[0].range.location == (text as NSString).range(of:"Jn.").location)
        #expect(found[0].range.location != text.distance(from:text.startIndex,to:text.range(of:"Jn.")!.lowerBound))
    }
    @Test func boundedNumericAndRomanBookPrefixesDoNotMatchWordFragments() throws {
        let text = "1 Juan 2:3 · II Samuel 4:5 · 3.º Juan 1:2 · IIICorintios 1:1 · I John 1:1 · II. Peter 2:1 · 4John 1:1 · microJohn 3:16 · MyJob 2:1"
        let found = try mentions(text)
        #expect(found.map { $0.citation.spans[0].lower.book } == ["1jn","2sa","3jn","1jn","2pe"])
        #expect(found.allSatisfy { $0.origin == .visibleText })
    }
    @Test func rangesListsAndInheritedChaptersUseExplicitCitationContext() throws {
        let text = "Jn 3:16–18,20; 4:1-3; 5. Ro 8:1; 9:2 y 1 Co 13:1–14:2."
        let found = try mentions(text)
        try #require(found.count == 3)
        #expect(found[0].label == "Jn 3:16–18,20; 4:1-3; 5")
        #expect(found[0].citation.spans.count == 4)
        let spans = found[0].citation.spans
        #expect(spans[0].lower.chapter == 3 && spans[0].lower.verse == 16 && spans[0].upper.verse == 18)
        #expect(spans[1].lower.verse == 20 && spans[1].upper.verse == 20)
        #expect(spans[2].lower.chapter == 4 && spans[2].upper.verse == 3)
        #expect(spans[3].lower.chapter == 5 && spans[3].lower.verse == 0 && spans[3].upper.verse == 65535)
        #expect(try BibleReferenceQuery.parse("John 3:17").matches(found[0]))
        #expect(!(try BibleReferenceQuery.parse("John 3:19").matches(found[0])))
        #expect(try BibleReferenceQuery.parse("John 5:8").matches(found[0]))
        #expect(try BibleReferenceQuery.parse("1 Cor 14:1").matches(found[2]))
    }
    @Test func wholeChaptersBooksAndCrossBookRangesHaveDeterministicBoundaries() throws {
        let found = try mentions("Genesis 2–4. Mt 28:20–Mr 1:2. Tobías 1:1.")
        try #require(found.count == 3)
        #expect(try BibleReferenceQuery.parse("Génesis").matches(found[0]))
        #expect(try BibleReferenceQuery.parse("I John").matches(try #require(mentions("1 John2:1").first)))
        #expect(try BibleReferenceQuery.parse("Ge 3:10").matches(found[0]))
        #expect(!(try BibleReferenceQuery.parse("Ge 5:1").matches(found[0])))
        #expect(try BibleReferenceQuery.parse("Mark 1:1").matches(found[1]))
        #expect(!(try BibleReferenceQuery.parse("Mark 1:3").matches(found[1])))
        #expect(try BibleReferenceQuery.parse("Tobit 1:1").matches(found[2]))
    }
    @Test func serializedIdentifiersKeepOriginalBookIDsAndExplicitEdition() throws {
        let found = try mentions("bible+rvr60.64.3.16 bible.61.1.1 bible.43.3.16")
        try #require(found.count == 2)
        #expect(found[0].citation.spans[0].lower.book == "jn" && found[0].citation.edition == "rvr60")
        #expect(found[1].citation.spans[0].lower.book == "mt")
        #expect(try BibleReferenceQuery.parse("John 3:16(RVR60)").matches(found[0]))
        #expect(!(try BibleReferenceQuery.parse("John 3:16(RVR95)").matches(found[0])))
        #expect(try BibleReferenceQuery.parse("Jn3:16").matches(found[0]))
        #expect(throws:(any Error).self) { try BibleReferenceQuery.parse("bible.43.3.16") }
    }
    @Test func explicitEditionFilteringNeverInfersOneFromUnqualifiedText() throws {
        let found = try mentions("Jn 3:16 (RVR60); John 3:16(ESV); Juan 3:16.")
        #expect(found.map { $0.citation.edition } == ["rvr60","esv",nil])
        let general = try BibleReferenceQuery.parse("Jn3:16"), rvr = try BibleReferenceQuery.parse("Jn3:16(rvr60)")
        #expect(found.filter(general.matches).count == 3)
        #expect(found.filter(rvr.matches).count == 1)
        #expect(!(try BibleReferenceQuery.parse("Jn3:16(ESV)").matches(found[2])))
    }
    @Test func mixedEditionContinuationsKeepEachExplicitVersionAndInheritedBook() throws {
        let text = "John3:16(RVR60),17-18(ESV),20(ESV);4:1(RVR95)"
        let found = try mentions(text)
        try #require(found.count == 3)
        #expect(found.map { $0.citation.edition } == ["rvr60","esv","rvr95"])
        #expect(found[1].citation.spans.count == 2 && found[2].citation.spans[0].lower.chapter == 4)
        #expect(try BibleReferenceQuery.parse("Jn3:17(ESV)").matches(found[1]))
        #expect(!(try BibleReferenceQuery.parse("Jn3:17(RVR60)").matches(found[1])))
        let query = try BibleReferenceQuery.parse(text)
        #expect(query.citations.count == 3 && found.allSatisfy(query.matches))
        let trailing = try #require(mentions("John3:16,18(ESV)").first)
        #expect(trailing.citation.spans.count == 2 && trailing.citation.edition == "esv")
        #expect(throws:(any Error).self) { try BibleReferenceQuery.parse("bible+esv.64.3.16(RVR60)") }
    }
    @Test func singleChapterBooksAndLegacyShortVerseTargetsKeepTheirActualChapter() throws {
        let found = try mentions("Jude 11–13;15 · Philemon 8 · 2 John 5 · Obadiah 3")
        try #require(found.count == 4)
        #expect(found.allSatisfy { $0.citation.spans.allSatisfy { $0.lower.chapter == 1 && $0.upper.chapter == 1 } })
        #expect(try BibleReferenceQuery.parse("Jud1:12").matches(found[0]))
        #expect(try BibleReferenceQuery.parse("Jude").matches(found[0]))
        #expect(!(try BibleReferenceQuery.parse("Jude14").matches(found[0])))
        let target = try #require(BibleReferenceMentions.extract("11",links:[.init(range:.init(location:0,length:2),target:"=rJud 11(RVR60)")]).first)
        #expect(target.citation.spans[0].lower.chapter == 1 && target.citation.spans[0].lower.verse == 11)
        #expect(try BibleReferenceQuery.parse("Jude11(RVR60)").matches(target))
        #expect(try BibleReferenceMentions.extract("label",links:[.init(range:.init(location:0,length:5),target:"=rGe 4")]).isEmpty)
        for invalid in ["Jude2:1","2 John2:1","bible.86.2.1"] { #expect(throws:(any Error).self) { try BibleReferenceQuery.parse(invalid) } }
    }
    @Test func typedLinkDestinationIsAuthoritativeOverAnOverlappingDisplayLabel() throws {
        let text = "😀 Jn3:16 · 18 · notes"
        let first = (text as NSString).range(of:"Jn3:16"), second = (text as NSString).range(of:"18")
        let found = try BibleReferenceMentions.extract(text,links:[
            .init(range:.init(location:first.location,length:first.length),target:"=rJn3:18(RVR60)"),
            .init(range:.init(location:second.location,length:second.length),target:"bible+esv.64.3.19")])
        #expect(found.count == 2 && found.allSatisfy { $0.origin == .explicitLink })
        #expect(found[0].label == "Jn3:16" && found[0].citation.spans[0].lower.verse == 18)
        #expect(!(try BibleReferenceQuery.parse("Jn3:16").matches(found[0])))
        #expect(try BibleReferenceQuery.parse("John3:19(ESV)").matches(found[1]))
    }
    @Test func linkedCitationSegmentsKeepUnlinkedContinuationMentions() throws {
        let text = "Jn3:16,20;4:1"
        let link = BibleReferenceSourceLink(range:.init(location:0,length:6),target:"=rRo8:1")
        let found = try BibleReferenceMentions.extract(text,links:[link,link])
        try #require(found.count == 2)
        #expect(found[0].origin == .explicitLink && found[0].citation.spans[0].lower.book == "ro")
        #expect(found[1].origin == .visibleText && found[1].citation.spans.count == 2)
        #expect(try BibleReferenceQuery.parse("Jn3:20").matches(found[1]))
        #expect(!(try BibleReferenceQuery.parse("Jn3:16").matches(found[1])))
        #expect(throws:(any Error).self) { try BibleReferenceMentions.extract(text,links:[link,.init(range:link.range,target:"=rGe1:1")]) }
        #expect(throws:(any Error).self) { try BibleReferenceMentions.extract(text,links:[.init(range:.init(location:0,length:0),target:"=rGe1:1")]) }
    }
    @Test func logicalArticleRangesDoNotJoinReferencesAcrossSharedHTMLArticles() throws {
        let text = "😀 John 3:16 | John 4:1 | John 5:2"
        let middle = (text as NSString).range(of:"John 4:1")
        let found = try BibleReferenceMentions.extract(text,within:.init(location:middle.location,length:middle.length))
        try #require(found.count == 1 && found[0].range.location == middle.location && found[0].label == "John 4:1")
        let broken = "John 3:" + "16"
        #expect(try BibleReferenceMentions.extract(broken,within:.init(location:0,length:7)).isEmpty)
        #expect(try BibleReferenceMentions.extract(broken,within:.init(location:7,length:2)).isEmpty)
        let link = BibleReferenceSourceLink(range:.init(location:middle.location,length:middle.length),target:"=rJn4:2")
        #expect(try BibleReferenceMentions.extract(text,within:.init(location:0,length:2),links:[link]).isEmpty)
    }
    @Test func explicitLinksCrossingArticleBoundariesHaveOneOwnerAndNoFalseVisibleMentions() throws {
        let text = "John3:16 John4:1"
        let link = BibleReferenceSourceLink(range:.init(location:0,length:text.utf16.count),target:"=rRo8:1")
        let first = try BibleReferenceMentions.extract(text,within:.init(location:0,length:9),links:[link])
        let second = try BibleReferenceMentions.extract(text,within:.init(location:9,length:text.utf16.count-9),links:[link])
        try #require(first.count == 1)
        #expect(first[0].range == .init(location:0,length:9) && first[0].citation.spans[0].lower.book == "ro")
        #expect(second.isEmpty)
    }
    @Test func malformedUnknownReversedAndOversizedSyntaxNeverBecomesAQuery() throws {
        for text in ["UnlistedBook 3:16","Jn 0:1","Jn3:0","Jn3:65536","Jn3:18-16","John3:16abc","bible.43.3.16","Jn3:16–Bogus","Jn3:16(RVR60)–Jn3:18(ESV)","Genesis1:1–Tobit1:1","Tobit1:1–Judith1:1","plain prose", "see John3:16", String(repeating:"a",count:4097)] {
            #expect(throws:(any Error).self, "Accepted invalid query: \(text)") { try BibleReferenceQuery.parse(text) }
        }
        #expect(try mentions("UnlistedBook 3:16, 2:1. microJohn 3:16. Jn0:1. Jn3:18-16").isEmpty)
    }
    @Test func unionQueriesOnlyAcceptExplicitReferenceSeparators() throws {
        let found = try mentions("John 3:16 and Romans 8:1")
        let query = try BibleReferenceQuery.parse("Jn3:16; Ro8:1")
        #expect(query.citations.count == 2 && found.allSatisfy(query.matches))
        #expect(throws:(any Error).self) { try BibleReferenceQuery.parse("Jn3:16 arbitrary words Ro8:1") }
    }
    @Test func malformedUTF16BoundsAndUnboundedLinkInputFailExplicitly() throws {
        for range in [SearchTextRange(location:-1,length:1),.init(location:1,length:1),.init(location:0,length:Int.max),.init(location:Int.max,length:1)] {
            #expect(throws:(any Error).self) { try BibleReferenceMentions.extract("😀 John3:16",within:range) }
        }
        #expect(throws:(any Error).self) { try BibleReferenceMentions.extract("😀",links:[.init(range:.init(location:1,length:1),target:"=rJn3:16")]) }
        #expect(throws:(any Error).self) { try BibleReferenceMentions.extract("John3:16",links:Array(repeating:.init(range:.init(location:0,length:8),target:"=rJn3:16"),count:100001)) }
        #expect(throws:(any Error).self) { try mentions("John 3:1" + String(repeating:",2",count:256)) }
    }
    @Test func largeMixedCitationStreamsKeepEveryDistinctOccurrence() throws {
        let text = Array(repeating:"John3:16(RVR60); bible+esv.64.3.18",count:3000).joined(separator:" · ")
        let clock = ContinuousClock(), before = clock.now
        let found = try mentions(text)
        try #require(found.count == 6000)
        #expect(found.filter { $0.citation.edition == "rvr60" }.count == 3000)
        #expect(found.filter { $0.citation.edition == "esv" }.count == 3000)
        #expect(Set(found.map(\.range)).count == 6000)
        print("Reference extraction: 6000 distinct mixed citations in \(before.duration(to:clock.now))")
    }
    @Test func codableRoundTripAndCancelledExtractionPreserveIdentity() async throws {
        let text = "😀 Jn 3:16–18(RVR60)", found = try mentions(text)
        let reopened = try JSONDecoder().decode([BibleReferenceMention].self,from:JSONEncoder().encode(found))
        #expect(reopened == found)
        let task = Task { try Task.checkCancellation();return try BibleReferenceMentions.extract(String(repeating:"John3:16 ",count:10000)) }
        task.cancel()
        do { _ = try await task.value;Issue.record("Cancelled extraction completed") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
}
