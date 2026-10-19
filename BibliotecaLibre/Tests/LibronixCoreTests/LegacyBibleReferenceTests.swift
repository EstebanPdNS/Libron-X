import Testing
@testable import LibronixCore

struct LegacyBibleReferenceTests {
    @Test func humanInputAcceptsCommonSeparatorsAbbreviationsSpacingAndLabels() {
        for raw in ["Génesis 4:1", "Genesis 4.1", "Gen4.1", "Gn 4,1", "Ge.4:1", "GEN. 4 : 1", "Gen 4 1",
                    "Génesis capítulo 4 versículo 1", "Gen cap. 4 v. 1", "Genesis chapter 4 verse 1", "Gen 4/1",
                    "Gn 4;1", "Gen\u{00a0}4：1", "Gen 4．1", "Gen 4，1"] {
            #expect(LegacyPassageQuery.parse(raw)?.normalizedKey == "ge 4:1")
            #expect(LegacyPassageQuery.parse(raw)?.original == raw)
        }
        for raw in ["1 Corintios 13.4", "1Corintios13:4", "1. Corintios 13,4", "1º Corintios 13 4", "I Corintios 13:4"] {
            #expect(LegacyPassageQuery.parse(raw)?.normalizedKey == "1co 13:4")
        }
        #expect(LegacyPassageQuery.parse("II Samuel 2.1")?.normalizedKey == "2sa 2:1")
        #expect(LegacyObservedBibleReference.parse("Gen 4.1") == nil)
    }
    @Test func navigationCanOpenAChapterWithoutChangingSourceLabelSemantics() {
        #expect(LegacyPassageQuery.navigationInput("Génesis 4")?.normalizedKey == "ge 4:1")
        #expect(LegacyPassageQuery.navigationInput("Gen cap. 4")?.normalizedKey == "ge 4:1")
        #expect(LegacyPassageQuery.navigationInput("Judas 5")?.normalizedKey == "jud 1:5")
        #expect(LegacyPassageQuery.navigationInput("Gen41")?.normalizedKey == "ge 41:1")
        #expect(LegacyPassageQuery.sourceReference("Ge 4") == nil)
        #expect(LegacyPassageQuery.sourceReference("Gen 4.1") == nil)
        #expect(LegacyPassageQuery.parse("Gen 4:1-3") == nil)
        for raw in ["Gen 4..1", "Gen 0.1", "Gen 4,0", "Gen 4:1 extra", "Gen 4:1:2"] {
            #expect(LegacyPassageQuery.navigationInput(raw) == nil)
        }
    }
    @Test func bibleCopyRangesRecognizeFlexibleVerseSeparators() throws {
        let single = try BibleCopyPassage.parse("Gen4.1")
        #expect(single.start.key == "ge 4:1" && !single.wholeChapter)
        let range = try BibleCopyPassage.parse("Génesis 4,1-3")
        #expect(range.start.key == "ge 4:1" && range.end.key == "ge 4:3" && !range.wholeChapter)
        #expect(try BibleCopyPassage.parse("Génesis 4").wholeChapter)
        for book in ["1Sa", "2Sa", "1Ki", "2Ch", "1Co", "2Th", "3Jn"] {
            let numbered = try BibleCopyPassage.parse("\(book) 1:1-\(book) 2:3")
            #expect(numbered.start.bookKey == numbered.end.bookKey)
            #expect(numbered.end.chapter == 2 && numbered.end.verse == 3)
        }
    }
    @Test func serializedAddressesUseDatatypeBookIDsAndPreserveTheSourceEdition() {
        for (raw, expected) in [("bible+rvr60.1.4.1", "ge 4:1"), ("bible.64.1.1", "jn 1:1"),
                                ("bible+esv.61.5.3", "mt 5:3"), ("bible.87.22.21", "re 22:21"),
                                ("bible.67.13.4", "1co 13:4"), ("BIBLE+RVR60.19.23.1", "ps 23:1")] {
            #expect(LegacyPassageQuery.parse(raw)?.normalizedKey == expected)
            #expect(LegacyPassageQuery.parse(raw)?.original == raw)
        }
        #expect(LegacyPassageQuery.parse("bible+rvr60.1.4.1")?.displayReference == "Ge 4:1")
        #expect(LegacyObservedBibleReference.parse("bible.1.4.1") == nil)
    }
    @Test func malformedUnsupportedAndNonBibleAddressesStayUnresolved() {
        for raw in ["page.1.4.1", "bible+.1.4.1", "bible+x+y.1.4.1", "bible.40.1.1", "bible.0.1.1", "bible.88.1.1",
                    "bible.1.0.1", "bible.1.1.0", "bible.1.-1.1", "bible.1.1.65536", "bible.1.1.1-3", "bible.1.1.1.extra", "bible.1.1.",
                    "bible+../../x.1.1.1", "bible.1.1." + String(repeating: "9", count: 700)] {
            #expect(LegacyPassageQuery.parse(raw) == nil)
        }
    }
    @Test func oneChapterSourceLabelsGainOnlyTheirKnownChapter() {
        for (raw, expected) in [("Ob 3", "ob 1:3"), ("Phm 4", "phm 1:4"), ("2 Jn 5", "2jn 1:5"), ("3 Jn 7", "3jn 1:7"), ("Jud 8", "jud 1:8")] {
            #expect(LegacyPassageQuery.sourceReference(raw)?.normalizedKey == expected)
            #expect(LegacyPassageQuery.parse(raw) == nil)
        }
        #expect(LegacyPassageQuery.sourceReference("Ge 3") == nil)
    }
}
