import Foundation
import Testing
@testable import LibronixCore

@Suite struct LegacyLocatorTests {
    @Test func numericIdentitiesPreserveEveryFieldAndDoNotConvertNamedResourceIDs() {
        let id = LegacyNumericResourceID.fromBKIDHex("2e001400060000003700")
        #expect(id?.identifier == "LLS:46.20.6" && id?.trailingField == 55)
        #expect(LegacyNumericResourceID.fromBKIDHex("01000000f60100008c00")?.identifier == "LLS:1.0.502")
        for value in ["LLS:OWN", "0100", "👁👁👁👁👁", "zz000000000000000000", "0100000003000000🦉"] {
            #expect(LegacyNumericResourceID.fromBKIDHex(value) == nil)
        }
    }
    @Test func parsesAbsoluteNamedAndCompactVariantsWithoutInventingMissingFields() throws {
        let named = try LegacyArticleLocator.parse("LLS-AOL:6479<Jn.CH1>.8.2")
        #expect(named.articleID == 6479 && named.articleLabel == "Jn.CH1" && named.offset == 8 && named.length == 2)
        let compact = try LegacyArticleLocator.parse("LLS-AO:25.16")
        #expect(compact.articleID == 25 && compact.offset == 16 && compact.length == 0)
        #expect(try LegacyArticleLocator.parse("LLS-A:25").absoluteCoordinates().offset == 0)
        for value in ["LLS-AOL:1.2.3\n", "LLS-AOL:1<>.2.3", "LLS-AOL:1<bad\nlabel>.2.3", "LLS-AOL:1.2.3.extra", "LLS-AOL:1.-2.3", "LLS-A:4294967296"] {
            #expect(throws: LegacyLocatorError.self) { try LegacyArticleLocator.parse(value) }
        }
    }
    @Test func relativeArithmeticMatchesTheVerifiedOriginalFieldOrderAndResetRules() throws {
        let same = try LegacyArticleLocator.parse("LLS-AOL:2.10.8::OL:-5.0").absoluteCoordinates()
        #expect(same.articleID == 2 && same.offset == 5 && same.length == 8)
        let moved = try LegacyArticleLocator.parse("LLS-AOL:2.10.8::OLA:3.4.1").absoluteCoordinates()
        #expect(moved.articleID == 3 && moved.offset == 3 && moved.length == 4)
        let length = try LegacyArticleLocator.parse("LLS-AOL:2.10.8::OLA:5.15.0").absoluteCoordinates()
        #expect(length.articleID == 2 && length.offset == 15 && length.length == 15)
        #expect(throws: LegacyLocatorError.self) { try LegacyArticleLocator.parse("LLS-AOL:0.0.0::OL:-1.0").absoluteCoordinates() }
        #expect(throws: LegacyLocatorError.self) { try LegacyArticleLocator.parse("LLS-AOL:4294967295.0.0::OLA:0.0.1").absoluteCoordinates() }
    }
    @Test func hintProjectionUsesOnlyTheVerifiedZeroWidthTransformationAndPreservesCoordinates() throws {
        let text = "a\u{200b}b", range = SearchTextRange(location: 2, length: 1)
        let values = ["start-article-length":"3", "end-article-length":"3", "start-hint":"a%EF%BB%BFb", "start-hint-length":"2", "end-hint":"b", "end-hint-length":"0"]
        try LegacyLocatorResolution.checkContext(values, text: text, range: range)
        #expect(text.utf16.count == 3 && (text as NSString).substring(with: range.nsRange) == "b")
        var wrong = values; wrong["start-hint"] = "x%EF%BB%BFb"
        #expect(throws: LegacyLocatorError.self) { try LegacyLocatorResolution.checkContext(wrong, text: text, range: range) }
        wrong = values; wrong["start-article-length"] = "4"
        #expect(throws: LegacyLocatorError.self) { try LegacyLocatorResolution.checkContext(wrong, text: text, range: range) }
    }
    @Test func contextComparisonNeverNormalizesDifferentUnicodeSequencesOrSkipsBadHints() {
        let values = ["start-hint":"%C3%A9x", "start-hint-length":"1"]
        #expect(LegacyLocatorResolution.contextChecks(values, text: "e\u{301}x", range: .init(location: 2, length: 1)).values.contains(false))
        #expect(LegacyLocatorResolution.contextChecks(["end-hint":"%ZZ"], text: "text", range: .init(location: 0, length: 1)).values.contains(false))
        #expect(LegacyLocatorResolution.contextChecks([:], text: "text", range: .init(location: Int.max, length: 1)) == ["range":false])
    }
    @Test func originalJumpDataKeepsTheReferenceWithoutExecutingOrGuessingCommandVariants() throws {
        let source = "jump|pos=LLS-AOL:92<BIBLE.64.1>.305.0|ref=bible+rvr60.64.1.5|res=LLS:RVR60NTRI"
        let destination = try LegacyJumpDestination.parse(source)
        #expect(destination.resourceID == "LLS:RVR60NTRI" && destination.position == "LLS-AOL:92<BIBLE.64.1>.305.0")
        #expect(destination.originalReference == "bible+rvr60.64.1.5")
        #expect(try LegacyJumpDestination.parse("jump|res=LLS:1.0.502|pos=LLS-AOL:6479<Jn.CH1>.8.2").originalReference == nil)
        for command in ["open|res=LLS:1.0.3|pos=LLS-A:0", "jump|res=LLS:1.0.3|res=LLS:1.0.4|pos=LLS-A:0",
                        "jump|res=LLS:1.0.3|pos=LLS-A:0|unknown=value", "jump|res=LLS:1.0.3|pos=", "jump|res=file:///own|pos=LLS-A:0"] {
            #expect(throws: LegacyLocatorError.self) { try LegacyJumpDestination.parse(command) }
        }
    }
}
