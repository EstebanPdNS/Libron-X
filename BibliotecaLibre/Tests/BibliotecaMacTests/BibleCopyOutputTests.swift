import AppKit
import Foundation
import Testing
@testable import LibronixCore
@testable import BibliotecaMac
import LibronixOutputMac

@MainActor @Suite struct BibleCopyOutputTests {
    @Test func customTemplatePatternsDriveTheActualFormattedPassage() async throws {
        let fixture = try OutputFixture(); defer { fixture.remove() }
        let source = try await BibleCopyService().prepare(fixture.resource, passage: .parse("Xy 1:1"), abbreviation: "Own")
        var style = BibleCopyOutputStyle(name: "Custom")
        style.citation = false; style.beforePassage.pattern = "START ^P^n"
        style.beforeVerse.pattern = "VERSE ^v: "; style.afterVerse.pattern = "^n"; style.afterPassage.pattern = "END"
        let result = try BibleCopyFormatter.format(source, style: style)
        #expect(result.bodyText.contains("START Xy 1:1"))
        #expect(result.bodyText.contains("VERSE 1:"))
        #expect(result.bodyText.contains("END"))
    }
    @Test func sourceAndBibleOnlyPoliciesKeepHeadingsAndVerseNumbersInTheirSeparatePaths() async throws {
        let fixture=try OutputFixture();defer{fixture.remove()}
        let source=try await BibleCopyService().prepare(fixture.resource,passage:.parse("Xy 1:2-2:1"),abbreviation:"Own")
        var style=BibleCopyOutputStyle.defaults[1];style.citation=false
        let only=try BibleCopyFormatter.format(source,style:style)
        #expect(only.bodyText=="Xy 1:2–2:1 (Own)\n2 Own second <tag>.\n1 Own next chapter.\n")
        #expect(!only.bodyText.contains("heading"))
        style=BibleCopyOutputStyle.defaults[0];style.citation=false
        let all=try BibleCopyFormatter.format(source,style:style)
        #expect(all.bodyText.contains("Own following heading") && !all.bodyText.contains("2 Own second"))
        style=BibleCopyOutputStyle.defaults[4];style.citation=false
        let joined=try BibleCopyFormatter.format(source,style:style)
        #expect(joined.bodyText.contains("Own second <tag>. 1 Own next"))
        #expect(joined.paragraphs.flatMap(\.runs).filter{$0.format.superscript}.map(\.text)==["2 ","1 "])
        style.paragraphs = .sourceParagraphs
        let originalParagraphs=try BibleCopyFormatter.format(source,style:style)
        #expect(originalParagraphs.paragraphs.count==2 && !originalParagraphs.bodyText.contains("heading"))
    }
    @Test func templateFormattingCannotTurnBodyOrExpandedBookNamesIntoMarkup() throws {
        var template=BibleCopyOutputTemplate("<B>^R</b> <script>x</script> ^? <i>tail")
        template.underline=true;template.superscript=true;template.subscriptText=true
        let context=BibleCopyOutputTemplateContext(passage:"Own 1:1",fullReference:"<i>Own</i> 1:1",shortReference:"O 1:1",fullBook:"Own",shortBook:"O",chapter:1,verse:1,abbreviation:"O")
        let runs=try BibleCopyFormatter.templateRuns(template,context:context)
        #expect(runs.map(\.text).joined()=="<i>Own</i> 1:1 <script>x</script> ^? tail")
        #expect(runs[0].format.bold && !runs[0].format.italic && runs.last?.format.italic == true)
        #expect(runs.allSatisfy{$0.format.underline && $0.format.superscript && $0.format.subscriptText})
    }
    @Test func clipboardRepresentationsKeepUnicodeFormattingAndStructuralFootnotes() async throws {
        let fixture=try OutputFixture();defer{fixture.remove()}
        let source=try await BibleCopyService().prepare(fixture.resource,passage:.parse("Xy 1:1"),abbreviation:"Own")
        var style=BibleCopyOutputStyle.defaults[1];style.beforeVerse.bold=true
        let formatted=try BibleCopyFormatter.format(source,style:style),payload=try NativeBibleCopyOutput.prepare(formatted)
        #expect(payload.text==payload.preview.string && payload.text.contains("🦉") && payload.text.contains("[1] Own output fixture."))
        let html=String(decoding:payload.html,as:UTF8.self),rtf=String(decoding:payload.footnoteRTF,as:UTF8.self)
        #expect(html.contains("mso-element:footnote") && html.contains("default-src 'none'"))
        #expect(rtf.contains("\\footnote") && rtf.contains("\\u-10178?") && rtf.contains("\\b "))
        let reloaded=try NSAttributedString(data:payload.rtf,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        #expect(reloaded.string==payload.text && reloaded.string.contains(formatted.notes[0].text))
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        try NativeBibleCopyOutput.copy(payload,to:board)
        #expect(board.string(forType:.string)==payload.text && board.data(forType:.rtf)==payload.rtf && board.data(forType:.html)==payload.html)
        #expect(board.pasteboardItems?.count==1)
    }
    @Test func sourceFootnotesRemainSeparateAndUnsupportedRenderingFailsBeforeClipboardMutation() async throws {
        let fixture=try OutputFixture();defer{fixture.remove()}
        let original=try await BibleCopyService().prepare(fixture.resource,passage:.parse("Xy 1:1"),abbreviation:"Own")
        let verse=original.verses[0],noteSource=verse.source
        let marker=BibleCopyFragment(text:"a",style:nil,sourceRange:.init(location:0,length:1),footnote:"own.note",isBibleText:false,isVerseNumber:false)
        let withNote=BibleCopyVerse(address:verse.address,sourceReference:verse.sourceReference,source:verse.source,paragraphKey:verse.paragraphKey,paragraphStyle:verse.paragraphStyle,fragments:verse.fragments+[marker])
        let source=BibleCopyDocument(resourceID:original.resourceID,passage:original.passage,title:original.title,abbreviation:original.abbreviation,verses:[withNote],
            footnotes:[.init(id:"own.note",marker:"a",text:"Own <reference> 🦉",source:noteSource)],citation:original.citation,typography:original.typography,sources:original.sources,fullParagraphs:original.fullParagraphs,sourceLanguages:[])
        var style=BibleCopyOutputStyle.defaults[1];style.copyFootnotes=true;style.citation=false
        let payload=try NativeBibleCopyOutput.prepare(BibleCopyFormatter.format(source,style:style))
        #expect(payload.document.notes.map(\.id)==["own.note"] && payload.text.contains("a Own <reference> 🦉"))
        #expect(String(decoding:payload.html,as:UTF8.self).contains("&lt;reference&gt;") && String(decoding:payload.footnoteRTF,as:UTF8.self).contains("\\footnote"))
        let reloaded=try NSAttributedString(data:payload.rtf,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        #expect(reloaded.string==payload.text && reloaded.string.contains("Own <reference> 🦉"))
        style.copyFootnotes=false
        #expect(try BibleCopyFormatter.format(source,style:style).notes.isEmpty)
        style.hebrew = .hebraicaII
        // A Hebrew output preference must not reject unrelated Latin text.
        #expect(try BibleCopyFormatter.format(source,style:style).paragraphs.map(\.text).joined().contains("Own first"))
        let hebrew = BibleCopyFragment(text:"שָׁלוֹם",style:nil,sourceRange:.init(location:0,length:"שָׁלוֹם".utf16.count),
            footnote:nil,isBibleText:true,isVerseNumber:false)
        let hebrewVerse = BibleCopyVerse(address:verse.address,sourceReference:verse.sourceReference,source:verse.source,
            paragraphKey:verse.paragraphKey,paragraphStyle:verse.paragraphStyle,fragments:[hebrew])
        let hebrewSource = BibleCopyDocument(resourceID:source.resourceID,passage:source.passage,title:source.title,
            abbreviation:source.abbreviation,verses:[hebrewVerse],footnotes:[],citation:source.citation,
            typography:source.typography,sources:source.sources,fullParagraphs:[],sourceLanguages:["he"])
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("Authored clipboard sentinel", forType:.string)
        let changeCount = board.changeCount
        #expect(throws:BibleCopyError.unsupportedLanguage) {
            let unsupported = try NativeBibleCopyOutput.prepare(BibleCopyFormatter.format(hebrewSource,style:style))
            try NativeBibleCopyOutput.copy(unsupported,to:board)
        }
        #expect(board.changeCount == changeCount && board.string(forType:.string) == "Authored clipboard sentinel")
    }
    @Test func aRejectedAggregateExpansionCannotReplaceTheClipboardWithAPartialCopy() async throws {
        let fixture = try OutputFixture(); defer { fixture.remove() }
        let source = try await BibleCopyService().prepare(fixture.resource, passage: .parse("Xy 1:1"), abbreviation: "Own")
        var style = BibleCopyOutputStyle(name: "Owned bounded copy")
        style.beforePassage.pattern = ""; style.beforeVerse.pattern = String(repeating: "x", count: 4000)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("Owned clipboard sentinel", forType: .string)
        let count = board.changeCount
        #expect(throws: BibleCopyError.limitExceeded) {
            let formatted = try BibleCopyFormatter.format(source, style: style, maximumUTF16Units: 128)
            try NativeBibleCopyOutput.copy(NativeBibleCopyOutput.prepare(formatted), to: board)
        }
        #expect(board.changeCount == count && board.string(forType: .string) == "Owned clipboard sentinel")
    }
    @Test func exportedStylesRetainUnknownSourceDataWhileEditingOwnedKnownFields() throws {
        let data=Data("""
        <lbx-copy-bible-verses-style name="Own" source="keep"><!-- own comment --><unknown x="y">own payload</unknown><options><option name="BibleTextOnly">true</option><option name="Future">false</option></options><templates><template name="BeforeVerse"><pattern xml:space="preserve">^v </pattern><extra>keep</extra><format name="FutureFormat">false</format></template></templates></lbx-copy-bible-verses-style>
        """.utf8)
        var style=try BibleCopyOutputStyle.importing(data,sourceSHA256:"own-hash"),original=style
        style.name="Own modified & <sample>";style.beforeVerse.pattern="<b>^R</b> | ";style.beforeVerse.subscriptText=true
        style.afterVerse.pattern="^n";style.paragraphs = .perVerse;style.hebrewLetters = .consonantsOnly
        let bytes=try style.exportedXML(),reloaded=try BibleCopyOutputStyle.importing(bytes)
        #expect(reloaded.name==style.name && reloaded.beforeVerse==style.beforeVerse && reloaded.paragraphs==style.paragraphs)
        #expect(reloaded.hebrewLetters == .consonantsOnly && reloaded.sourceXML?.attributes["source"]=="keep")
        #expect(reloaded.sourceXML?.child(named:"unknown")?.text=="own payload" && reloaded.sourceXML?.comments.contains(" own comment ")==true)
        #expect(reloaded.sourceXML?.child(named:"templates")?.children(named:"template").first(where:{$0.attributes["name"]=="BeforeVerse"})?.child(named:"extra")?.text=="keep")
        #expect(style.sourceXML==original.sourceXML && style.sourceSHA256=="own-hash")
        original.schemaVersion=2
        #expect(throws:PersonalStateError.self){try original.exportedXML()}
    }
    @Test func styleDraftsAndDeletionPreserveDefaultsAndSurviveRestartWithConcurrentChangeProtection() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=BibleCopySettingsStore(directory:root),defaults=store.value.styles
        var draft=defaults[1];draft.id=UUID();draft.preset=nil;draft.name="Own canceled draft";draft.citation=false
        #expect(store.value.styles==defaults && !FileManager.default.fileExists(atPath:root.appendingPathComponent("bible-copy.json").path))
        draft.name="Own committed";try store.saveStyle(draft,replacing:nil)
        try store.change{$0.keepOpen=true;$0.passage="Xy 1:1-2";$0.referenceLanguage = .spanish}
        let reopened=BibleCopySettingsStore(directory:root)
        #expect(reopened.value==store.value && reopened.value.customStyles==[draft] && reopened.value.styles.prefix(6)==defaults[...])
        var updated=draft;updated.beforeVerse.pattern="^R | ";try store.saveStyle(updated,replacing:draft)
        var stale=draft;stale.name="Own stale change"
        #expect(throws:PersonalStateError.self){try reopened.saveStyle(stale,replacing:draft)}
        #expect(throws:PersonalStateError.self){try store.saveStyle(draft,replacing:draft)}
        #expect(throws:BibleCopyError.invalidStyle){try store.saveStyle(defaults[0],replacing:nil)}
        try store.deleteStyle(updated)
        #expect(store.value.customStyles.isEmpty && store.value.selectedStyleID==defaults[1].id && BibleCopySettingsStore(directory:root).value==store.value)
        #expect(FileManager.default.fileExists(atPath:root.appendingPathComponent("bible-copy.json.previous").path))
    }
    @Test func futureStateCannotBeOverwrittenAndChangingFieldsOrStylesInvalidatesCopyEligibility() async throws {
        let fixture=try OutputFixture();defer{fixture.remove()}
        let root=fixture.root.appendingPathComponent("copy-personal"),settings=BibleCopySettingsStore(directory:root),model=BibleCopyModel(settings:settings)
        model.resourceID=fixture.resource.id;model.passage="Xy 1:1";model.keepOpen=true;model.isPresented=true
        model.prepare(resources:[fixture.resource]);await wait(model)
        #expect(model.canCopy)
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        model.copy(to:board);#expect(model.isPresented && board.string(forType:.string)==model.payload?.text)
        model.passage="Xy 1:2";#expect(!model.canCopy && model.payload==nil)
        model.prepare(resources:[fixture.resource]);model.invalidate();await Task.yield()
        #expect(!model.isPreparing && !model.canCopy)
        var own=settings.value.styles[1];own.id=UUID();own.preset=nil;own.name="Own changed"
        try settings.saveStyle(own,replacing:nil);model.styleID=own.id;model.prepare(resources:[fixture.resource]);await wait(model)
        #expect(model.canCopy)
        var changed=own;changed.beforeVerse.pattern="changed ^v ";try settings.saveStyle(changed,replacing:own)
        #expect(!model.canCopy)
        var future=settings.value;future.schemaVersion=2
        let bytes=try JSONEncoder().encode(future),path=root.appendingPathComponent("bible-copy.json");try bytes.write(to:path)
        let newer=BibleCopySettingsStore(directory:root);#expect(newer.errorMessage != nil)
        #expect(throws:PersonalStateError.self){try newer.change{$0.keepOpen=false}}
        #expect(try Data(contentsOf:path)==bytes)
    }
    private func wait(_ model:BibleCopyModel) async {
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while model.isPreparing && ContinuousClock.now<deadline { try? await Task.sleep(for:.milliseconds(2)) }
    }
}
