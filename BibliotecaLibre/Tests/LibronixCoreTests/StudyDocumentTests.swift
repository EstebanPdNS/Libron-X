import Foundation
import Testing
@testable import LibronixCore

@Suite struct StudyDocumentTests {
    @Test func notesImportKeepsBodiesPropertiesAndThreeDifferentAnchorTypes() throws {
        let data = Data("""
        <lbx-annotations category="Annotations" name="Own notes" guid="original-document-id"><metadata><unknown>preserve</unknown></metadata>
        <annotation guid="general" author="Own author" type="question" style="Box"><title>General</title><content type="text/html"><![CDATA[<P><STRONG>Own <SPAN lbxrt:xref="bible.64.1.1">John 1:1</SPAN></STRONG></P>]]></content></annotation>
        <annotation guid="selection" resource-id="LLS:OWN" special="pos=LLS-AOL:92&lt;CH.1&gt;.8.2|version=original"><title>Selection</title><content type="text/html"><![CDATA[<P>Selected text note.</P>]]></content></annotation>
        <annotation guid="reference" reference="bible+own.64.1.1"><title>Reference</title><content type="text/html"><![CDATA[<P>Reference note.</P>]]></content></annotation></lbx-annotations>
        """.utf8)
        let doc = try StudyDocument.importingLegacyXML(data, sourceSHA256: "source-hash")
        #expect(doc.notes.map { $0.anchor.kind } == [.general, .legacySelection, .legacyReference])
        #expect(doc.notes[0].sourceAttributes["author"] == "Own author")
        #expect(doc.notes[1].anchor.location == nil && doc.notes[1].anchor.selection == nil)
        #expect(doc.notes[1].anchor.legacyAttributes["special"] == "pos=LLS-AOL:92<CH.1>.8.2|version=original")
        #expect(doc.sourceXML?.child(named: "metadata")?.child(named: "unknown")?.text == "preserve")
        let reloaded = try JSONDecoder().decode(StudyDocument.self, from: JSONEncoder().encode(doc))
        #expect(reloaded == doc)
        var edited = doc; edited.notes[0].title = "Edited own title"; edited.notes[0].editedRTF = Data("own native edit".utf8)
        #expect(edited.sourceXML == doc.sourceXML && edited.notes[0].sourceBody == doc.notes[0].sourceBody)
    }
    @Test func verseListsPreserveOrderRangesResourceIDsAndStyleWithoutGuessingTheirCanon() throws {
        let data = Data("""
        <lbx-verse-list name="Own list" category="VerseLists"><refs type1="LLS:1.0.3" type2="LLS:1.0.71" style="BothTwoColumns" canonical-sort="no"><ref>bible.64.1.1-64.1.2</ref><ref>bible.1.1.1</ref></refs></lbx-verse-list>
        """.utf8)
        let doc = try StudyDocument.importingLegacyXML(data)
        #expect(doc.kind == .verseList && doc.presentation == "BothTwoColumns")
        #expect(doc.verses.map(\.reference) == ["bible.64.1.1-64.1.2", "bible.1.1.1"])
        #expect(doc.verses.allSatisfy { $0.location == nil })
        #expect(doc.referenceAttributes == ["type1":"LLS:1.0.3", "type2":"LLS:1.0.71", "style":"BothTwoColumns", "canonical-sort":"no"])
        #expect(try JSONDecoder().decode(StudyDocument.self, from: JSONEncoder().encode(doc)) == doc)
    }
    @Test func verseOrganizationPreservesIdentitiesAndRejectsUnrecognizedEntriesWithoutChangingOrder() throws {
        var doc = StudyDocument(title: "Own", kind: .verseList)
        doc.verses = [StudyVerseEntry(reference: "Juan 3:16"), StudyVerseEntry(reference: "Génesis 1:1"), StudyVerseEntry(reference: "John 3:16")]
        let original = doc.verses
        try StudyVerseOrganization.move(original[1].id, by: 1, in: &doc)
        #expect(doc.verses.map(\.id) == [original[0].id, original[2].id, original[1].id])
        try StudyVerseOrganization.sortCanonically(&doc)
        #expect(doc.verses.map(\.id) == [original[1].id, original[0].id, original[2].id])
        doc.verses.append(StudyVerseEntry(reference: "unknown reference"))
        let before = doc
        #expect(throws: (any Error).self) { try StudyVerseOrganization.sortCanonically(&doc) }
        #expect(doc == before)
        let encoded = try JSONEncoder().encode(doc)
        #expect(try JSONDecoder().decode(StudyDocument.self, from: encoded) == doc)
    }
    @Test func verseEditionSurvivesRoundTripWithoutRewritingImportedProvenance() throws {
        let resource = LibraryResource(location: URL(fileURLWithPath: "/owned/edition.LSF"), title: "Owned edition", byteCount: 0,
            format: .legacyLSF, support: .metadataOnly, provenance: .fileName, legacyIdentifier: "owned-id")
        var document = try StudyDocument.importingLegacyXML(Data("<lbx-verse-list name='Owned'><refs style='BothTwoColumns' type1='preserve'><ref>John 3:16</ref></refs></lbx-verse-list>".utf8))
        let original = document
        document.verseListEdition = StudyVerseListEdition(resource)
        #expect(throws: PersonalStateError.self) { try document.validate() }
        document.schemaVersion = 4; try document.validate()
        let reopened = try JSONDecoder().decode(StudyDocument.self, from: JSONEncoder().encode(document))
        try reopened.validate()
        #expect(reopened == document && reopened.verseListEdition?.title == "Owned edition")
        #expect(reopened.sourceXML == original.sourceXML && reopened.referenceAttributes == original.referenceAttributes)
        #expect(reopened.verseListEdition?.resolve(in: [resource]) == resource)
        let replacement = LibraryResource(location: resource.location, title: resource.title, byteCount: 0,
            format: resource.format, support: resource.support, provenance: resource.provenance, legacyIdentifier: "different-id")
        let wrongFormat = LibraryResource(location: resource.location, title: resource.title, byteCount: 0,
            format: .eSwordSQLite, support: resource.support, provenance: resource.provenance, legacyIdentifier: resource.legacyIdentifier)
        #expect(reopened.verseListEdition?.resolve(in: [replacement, wrongFormat]) == nil)
        let old = try JSONDecoder().decode(StudyDocument.self, from: JSONEncoder().encode(original))
        #expect(old.verseListEdition == nil && old.presentation == "BothTwoColumns")
        var future = document; future.schemaVersion = 5
        #expect(throws: PersonalStateError.self) { try future.validate() }
        var wrongKind = document; wrongKind.kind = .notebook; wrongKind.verses = []
        #expect(throws: PersonalStateError.self) { try wrongKind.validate() }
    }
    @Test func editingAVersePreservesItsIdentityAndClearsOnlyAnObsoleteDestination() throws {
        var document = StudyDocument(title: "Owned list", kind: .verseList)
        let location = ReaderLocation(resourceID: "owned", format: .legacyLSF, sectionOrdinal: 0, reference: "Ge1:1")
        let entry = StudyVerseEntry(reference: "Ge1:1", location: location)
        document.verses = [entry]; document.referenceAttributes = ["original": "preserve"]
        try StudyVerseOrganization.changeReference(entry, to: " Ge1:1 ", in: &document)
        #expect(document.verses == [entry])
        try StudyVerseOrganization.changeReference(entry, to: "Ge1:2", in: &document)
        #expect(document.verses[0].id == entry.id && document.verses[0].location == nil && document.verses[0].reference == "Ge1:2")
        let before = document
        #expect(throws: PersonalStateError.self) { try StudyVerseOrganization.changeReference(entry, to: "Ge1:3", in: &document) }
        #expect(document == before && document.referenceAttributes == ["original": "preserve"])
        #expect(throws: BibleSearchRangeError.invalidExpression) {
            try StudyVerseOrganization.changeReference(document.verses[0], to: " ", in: &document)
        }
    }
    @Test func inertRichTextProjectionKeepsNestedFormattingLinksAndUnicodeEntities() {
        let spans = NoteHTMLProjection.spans(#"<P align=left><STRONG>Alpha <SPAN lbxrt:xref="bible.64.1.1"><I>John &amp; &#x1F989;</I></SPAN></STRONG><BR>שלום&nbsp;λόγος</P>"#)
        #expect(spans.map(\.text).joined() == "Alpha John & 🦉\nשלום\u{a0}λόγος\n")
        #expect(spans.first?.bold == true)
        let linked = spans.first { $0.reference != nil }
        #expect(linked?.bold == true && linked?.italic == true && linked?.reference == "bible.64.1.1")
        #expect(spans.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.bold == false)
    }
    @Test func activeOrExternalHTMLIsProjectedWithoutLoadingOrExecutingIt() {
        let source = #"<P>Before<script>fetch('https://example.invalid/private')</script><style>body{color:red}</style><img src="https://example.invalid/pixel"><SPAN title="x>y"><U>After</U></SPAN></P>"#
        let spans = NoteHTMLProjection.spans(source)
        #expect(spans.map(\.text).joined() == "BeforeAfter\n")
        #expect(spans.first(where: { $0.text == "After" })?.underline == true)
    }
    @Test func unsupportedRootsDTDAndInvalidNativeAnchorsFailExplicitly() {
        #expect(throws: MetadataReadError.self) { try StudyDocument.importingLegacyXML(Data("<unrecognized/>".utf8)) }
        #expect(throws: MetadataReadError.self) { try StudyDocument.importingLegacyXML(Data("<!DOCTYPE lbx-annotations><lbx-annotations name='Own'/>".utf8)) }
        var doc = StudyDocument(title: "Own", kind: .notebook)
        doc.notes = [StudyNote(anchor: StudyNoteAnchor(kind: .nativeSelection))]
        #expect(throws: PersonalStateError.self) { try doc.validate() }
    }
    @Test func importedInlineStylesProjectWithoutLoadingExternalContent() {
        let spans = NoteHTMLProjection.spans("<span style=\"font-weight:700;font-style:italic;text-decoration:underline line-through;color:#c01020\">Owned</span>")
        #expect(spans.count == 1 && spans[0].text == "Owned")
        #expect(spans[0].bold && spans[0].italic && spans[0].underline && spans[0].strikeout && spans[0].foregroundRGB == 0xc01020)
        let paragraph = NoteHTMLProjection.spans("<p style=\"color:#123456\"><b>Styled</b> text</p>")
        #expect(paragraph.first?.bold == true && paragraph.first?.foregroundRGB == 0x123456)
        #expect(paragraph.contains { $0.text == " text" && !$0.bold && $0.foregroundRGB == 0x123456 })
        let override = NoteHTMLProjection.spans("<b>bold <span style=\"font-weight:normal\">normal</span> bold</b>")
        #expect(override.map(\.bold) == [true, false, true])
        let colors = NoteHTMLProjection.spans("<span style=\"color:#abc\">A</span><font color=\"RED\">B</font>")
        #expect(colors.map(\.foregroundRGB) == [0xaabbcc, 0xff0000])
    }

}
