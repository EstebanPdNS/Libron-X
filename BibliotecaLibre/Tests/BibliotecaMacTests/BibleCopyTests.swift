import Foundation
import Testing
@testable import LibronixCore

@MainActor @Suite struct BibleCopyTests {
    @Test func parsesBoundedSingleVerseChapterAndCrossChapterWithoutInferringVerseCounts() throws {
        let short=try BibleCopyPassage.parse("Juan 1:51–2:2")
        #expect(short.start.bookKey=="jn" && short.end.bookKey=="jn" && short.end.chapter==2 && short.end.verse==2)
        #expect(try BibleCopyPassage.parse("John 1").wholeChapter)
        #expect(try BibleCopyPassage.parse("Génesis 1:1-3").end.verse==3)
        #expect(try BibleCopyPassage.parse("Juan 1:1").start == BibleCopyPassage.parse("Jn 1:1").start)
        #expect(throws:BibleCopyError.reversedPassage) { try BibleCopyPassage.parse("John 2:2-1:51") }
        for invalid in ["", "John", "John 0:1", "John 1:0", "John 1:1-", "John 1:1-2-3", String(repeating:"x",count:513)] {
            #expect(throws:BibleCopyError.self) { try BibleCopyPassage.parse(invalid) }
        }
    }
    @Test func sourceSequenceCrossesPhysicalArticlesAndKeepsInterveningHeadingOnlyInAllText() async throws {
        let fixture=try OutputFixture();defer{fixture.remove()}
        let service=BibleCopyService()
        let doc=try await service.prepare(fixture.resource,passage:.parse("Xy 1:2-2:1"),abbreviation:"Own")
        #expect(doc.verses.map(\.address.key)==["xy 1:2","xy 2:1"])
        #expect(doc.verses.map(\.text)==["Own second <tag>.","Own next chapter."])
        let memory = try ScriptureMemorySource.card(reference: "Xy 1:2-2:1", document: doc)
        #expect(memory.passage == "Own second <tag>.\nOwn next chapter." && memory.source == doc.title)
        #expect(doc.fullParagraphs.map(\.text).joined(separator:"\n").contains("Own following heading"))
        #expect(doc.sources.map(\.sectionOrdinal)==[1,3])
        let chapter=try await service.prepare(fixture.resource,passage:.parse("Xy 1"),abbreviation:"Own")
        #expect(chapter.verses.map(\.address.verse)==[1,2])
        let alias=try await service.prepare(fixture.resource,passage:.parse("XY 1:1"),abbreviation:"Own")
        #expect(alias.verses.count==1 && alias.verses[0].text=="Own first 🦉.")
    }
    @Test func missingRangeBoundaryBrokenSequenceAndBudgetsCannotProduceAnApparentlyCompletePassage() async throws {
        let fixture=try OutputFixture();defer{fixture.remove()};let service=BibleCopyService()
        let absent=try await service.prepare(fixture.resource,passage:.parse("Xy 999:1"),abbreviation:"Own")
        #expect(!absent.hasVerseText && !absent.citation.isEmpty && absent.sources.isEmpty)
        #expect(throws: (any Error).self) { try ScriptureMemorySource.card(reference: "Xy 999:1", document: absent) }
        await #expect(throws:BibleCopyError.missingBoundary) { try await service.prepare(fixture.resource,passage:.parse("Xy 1:1-999:1"),abbreviation:"Own") }
        await #expect(throws:BibleCopyError.limitExceeded) { try await service.prepare(fixture.resource,passage:.parse("Xy 1:1"),abbreviation:"Own",maximumCharacters:1) }
        let gap=try OutputFixture(secondVerse:3);defer{gap.remove()}
        await #expect(throws:BibleCopyError.incompleteSource) { try await service.prepare(gap.resource,passage:.parse("Xy 1:1-3"),abbreviation:"Own") }
        let task=Task { try await service.prepare(fixture.resource,passage:.parse("Xy 1:1-2"),abbreviation:"Own") };task.cancel()
        do { _=try await task.value;Issue.record("Canceled request returned a copy document") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    }
    @Test func aSingleVerseDoesNotRequireTheUnselectedRestOfItsChapter() async throws {
        let fixture=try OutputFixture();defer{fixture.remove()};let service=BibleCopyService()
        let one=try await service.prepare(fixture.resource,passage:.parse("Xy 1:1"),abbreviation:"Own",maximumArticles:1,maximumCharacters:fixture.text[0].utf16.count)
        #expect(one.verses.map(\.text)==[fixture.text[0]] && one.sources.map(\.sectionOrdinal)==[0])
        await #expect(throws:BibleCopyError.limitExceeded) { try await service.prepare(fixture.resource,passage:.parse("Xy 1:1-2"),abbreviation:"Own",maximumArticles:1) }
        await #expect(throws:BibleCopyError.limitExceeded) { try await service.prepare(fixture.resource,passage:.parse("Xy 1"),abbreviation:"Own",maximumArticles:1) }
    }
    @Test func styleImportsPreserveTemplatesFalseEmptyFormatsAndSeparateLanguagePolicies() throws {
        let xml="""
        <lbx-copy-bible-verses-style name="Own style"><options><option name="BibleTextOnly">true</option><option name="BibliographicCitation">false</option><option name="BTORemoveParagraphs">true</option></options><templates><template name="AfterVerse"><pattern>^n</pattern></template><template name="BeforeVerse"><pattern xml:space="preserve">^R | </pattern><format name="Bold"/><format name="Superscript">true</format><format name="Subscript">false</format></template></templates><languages><language name="he">unicode</language><language name="he_letters">consonants-only</language></languages></lbx-copy-bible-verses-style>
        """
        let style=try BibleCopyOutputStyle.importing(Data(xml.utf8),sourceSHA256:"own")
        #expect(style.beforeVerse.pattern=="^R | " && !style.beforeVerse.bold && style.beforeVerse.superscript)
        #expect(style.bibleTextOnly && !style.citation && style.paragraphs == .perVerse && style.hebrewLetters == .consonantsOnly)
        #expect(style.sourceXML?.attributes["name"]=="Own style" && style.sourceSHA256=="own")
        let context=BibleCopyOutputTemplateContext(passage:"Own 1:1-2",fullReference:"Own 1:2",shortReference:"Ow 1:2",fullBook:"Own",shortBook:"Ow",chapter:1,verse:2,abbreviation:"O")
        #expect(try BibleCopyOutputTemplateExpander.expand("^R | ^v ^a ^^ ^n",context:context)=="Own 1:2 | 2 O ^ \n")
        #expect(try BibleCopyOutputTemplateExpander.expand("^B ^b ^c ^r ^p ^?",context:context)=="Own Ow 1 Ow 1:2 Own 1:1-2 ^?")
        #expect(BibleCopyOutputStyle.defaults.count==6 && Set(BibleCopyOutputStyle.defaults.map(\.id)).count==6)
    }
    @Test func HebrewProjectionKeepsSourceUntouchedAndAppliesTheTwoDistinctLetterPolicies() {
        let source="מַמ׃ פַפ־ נַנְ ך"
        #expect(BibleCopyScriptProjection.hebrew(source)=="מַם׃ פַף־ נַןְ ך")
        #expect(BibleCopyScriptProjection.hebrew("בַ֑מ׃",letters:.consonantsAndVowels)=="בַם׃")
        #expect(BibleCopyScriptProjection.hebrew("בַ֑מ־נָמ׃",letters:.consonantsOnly)=="בם נם")
        #expect(source=="מַמ׃ פַפ־ נַנְ ך")
    }
    @Test func proceduralTransliterationPreservesTheBoundedPolicyForMatresBreathingClustersAndPunctuation() {
        #expect(BibleCopyTransliterator.hebrewLogos("בִי")=="bî")
        #expect(BibleCopyTransliterator.hebrewLogos("בֵי")=="bê")
        #expect(BibleCopyTransliterator.hebrewLogos("וֹ")=="ô")
        #expect(BibleCopyTransliterator.hebrewLogos("לוּעַ")=="lûaʿ")
        #expect(BibleCopyTransliterator.hebrewLogos("בַלְמַ")=="balma")
        #expect(BibleCopyTransliterator.hebrewLogos("בַלְמ")=="baləm")
        #expect(BibleCopyTransliterator.greekSBL("Αὑ")=="Hau")
        #expect(BibleCopyTransliterator.greekSBL("γκ ΘΑ")=="nk THA")
        #expect(BibleCopyTransliterator.greekSBL("Ῥα ;·")=="Rha ?;")
    }
}
