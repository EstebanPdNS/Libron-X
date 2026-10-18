import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

struct CommentaryRangeTests {
    @Test func explicitHeadingRangesCoverOnlyObservedVersesAndSpecificNotesWin() throws {
        let anchors = (1...7).map { verse in
            LegacyReferenceAnchor(reference: "Ge 1:\(verse)", flags: 0, dataTypeCode: 16,
                characterOffset: verse - 1, decodedOffset: UInt64(verse - 1), referenceFormatFlags: 0)
        }
        func link(_ verse: Int, _ ordinal: Int) -> LegacyInlineLink {
            var link = LegacyInlineLink(range: .init(location: verse - 1, length: 1), label: "\(verse)", sourceName: "authored", sectionOrdinal: ordinal)
            link.role = .studyCommentary; return link
        }
        func heading(_ label: String, _ reference: String) throws -> ReaderCommentaryIndex.Heading {
            .init(text: label + " Authored study note.", inlineLinks: [
                .init(range: .init(location: 0, length: label.utf16.count), label: label,
                    sourceName: "authored", target: .bible(try #require(LegacyBibleLinkReference.parse("=r" + reference))))
            ])
        }
        let headings = [10: try heading("1:1–5", "Ge 1:1"), 11: try heading("1:3", "Ge 1:3"),
            12: try heading("1:1–7", "Ge 1:6")]
        let result = ReaderCommentaryIndex.build(anchors: anchors, textLength: 7,
            links: [link(1, 10), link(3, 11), link(6, 12)]) { headings[$0] }
        #expect(result == ["ge 1:1": 10, "ge 1:2": 10, "ge 1:3": 11, "ge 1:4": 10, "ge 1:5": 10, "ge 1:6": 12])
        // The mismatched heading must not extend verse 6 to verse 7.
        #expect(result["ge 1:7"] == nil && result["ge 1:8"] == nil)
    }
    @Test func aVerifiedCrossChapterHeadingCoversLaterChaptersWithoutBorrowingAnotherBook() throws {
        let owner = try #require(LegacyPassageQuery.sourceReference("Ge 1:30"))
        let label = "1:30–2:3"
        let heading = ReaderCommentaryIndex.Heading(text: label + " Authored overview.", inlineLinks: [
            .init(range: .init(location: 0, length: label.utf16.count), label: label, sourceName: "authored",
                target: .bible(try #require(LegacyBibleLinkReference.parse("=rGe 1:30"))))
        ])
        let addresses = ["Ge 1:29", "Ge 1:30", "Ge 1:31", "Ge 2:1", "Ge 2:3", "Ge 2:4", "Ex 2:1"].compactMap(LegacyPassageQuery.sourceReference)
        let result = ReaderCommentaryIndex.build(owners: [(owner, 10)], addresses: addresses) { _ in heading }
        #expect(Set(result.keys) == ["ge 1:30", "ge 1:31", "ge 2:1", "ge 2:3"])
    }
    @Test func laterCitationsAndOrdinaryFootnotesNeverExtendCommentaryCoverage() throws {
        let anchors = (1...3).map { verse in
            LegacyReferenceAnchor(reference: "Ge 1:\(verse)", flags: 0, dataTypeCode: 16,
                characterOffset: verse - 1, decodedOffset: UInt64(verse - 1), referenceFormatFlags: 0)
        }
        var owner = LegacyInlineLink(range: .init(location: 0, length: 1), label: "1", sourceName: "authored", sectionOrdinal: 10)
        owner.role = .studyCommentary
        let citation = LegacyInlineLink(range: .init(location: 10, length: 5), label: "1:1–3", sourceName: "authored",
            target: .bible(try #require(LegacyBibleLinkReference.parse("=rGe 1:1-3"))))
        let footnote = LegacyInlineLink(range: .init(location: 1, length: 1), label: "2", sourceName: "authored", sectionOrdinal: 11)
        let result = ReaderCommentaryIndex.build(anchors: anchors, textLength: 3, links: [owner, footnote]) { _ in
            .init(text: "Authored: 1:1–3 citation.", inlineLinks: [citation])
        }
        #expect(result == ["ge 1:1": 10])
    }
}
