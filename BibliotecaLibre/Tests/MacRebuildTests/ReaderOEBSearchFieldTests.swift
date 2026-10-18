import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct ReaderOEBSearchFieldTests {
    @Test func nativeDOMFieldsUseExplicitSourceSemanticsAndRetainTheExactVisibleProjection() async throws {
        _=NSApplication.shared
        let html="<span id='a1'></span><h1 epub:type='fulltitle'>TitleNeedle</h1><p>BodyNeedle <q>QuoteNeedle</q></p><aside role='doc-footnote'><p>NoteNeedle 😀</p></aside><p class='footnote'>ClassIsBody</p><span id='a2'></span><h2>SecondHeading</h2><aside epub:type='footnote'>OtherNote</aside><p class='hidden'>HiddenNote</p>"
        let fixture=try AuthoredOEBFixture(chapterBody:html);defer{fixture.remove()}
        let original=try Data(contentsOf:fixture.resource.location)
        let book=try await LibronixOEBService.shared.prepare(fixture.resource.location)
        let page=try await ReaderOEBTextSource.shared.read(book:book,path:"Chapter.html",viewport:.init())
        let fields=try #require(page.fieldDirectory)
        func search(_ source:String) throws -> TextSearchResult {try TextSearchEngine.search(query:SearchQueryParser.parse(source),in:page.text,fields:fields)}
        #expect(page.text == "TitleNeedleBodyNeedle QuoteNeedleNoteNeedle 😀ClassIsBodySecondHeadingOtherNote")
        for (query,expected) in [("title:TitleNeedle","TitleNeedle"),("body:BodyNeedle","BodyNeedle"),("footnote:NoteNeedle","NoteNeedle"),("quote:QuoteNeedle","QuoteNeedle"),("heading:SecondHeading","SecondHeading"),("body:ClassIsBody","ClassIsBody")] {
            let result=try search(query);#expect(result.hitCount == 1)
            #expect((page.text as NSString).substring(with:result.hits[0].range.nsRange) == expected)
        }
        for query in ["body:TitleNeedle","body:NoteNeedle","footnote:BodyNeedle","footnote:ClassIsBody","body:HiddenNote"] {#expect(try search(query).matchesQuery == false)}
        let second=try #require(page.articleRanges[2]),note=try search("footnote:OtherNote")
        #expect(NSLocationInRange(note.hits[0].range.location,second))
        #expect(fields.regions[.bibleText] == nil)
        #expect(try Data(contentsOf:fixture.resource.location) == original)
    }
    @Test func unmarkedHeadingsAreNotInventedTitlesAndMissingDeclaredNotesRemainKnownEmpty() async throws {
        _=NSApplication.shared
        let fixture=try AuthoredOEBFixture();defer{fixture.remove()}
        let book=try await LibronixOEBService.shared.prepare(fixture.resource.location)
        let page=try await ReaderOEBTextSource.shared.read(book:book,path:"Chapter.html",viewport:.init())
        let fields=try #require(page.fieldDirectory)
        #expect(fields.regions[.title]?.isEmpty == true && fields.regions[.footnote]?.isEmpty == true)
        let heading=try TextSearchEngine.search(query:SearchQueryParser.parse("heading:Gamma"),in:page.text,fields:fields)
        #expect(heading.hitCount == 1 && heading.hits[0].range.location == 0)
        let cached=try await ReaderOEBTextSource.shared.read(book:book,path:"Chapter.html",viewport:.init())
        #expect(cached.text == page.text && cached.fieldDirectory == fields)
    }
}
