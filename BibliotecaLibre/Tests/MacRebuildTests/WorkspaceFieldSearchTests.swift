import AppKit
import WebKit
import Foundation
import Testing
import CSQLite
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct WorkspaceFieldSearchTests {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {if condition(){return};try await Task.sleep(for:.milliseconds(5))}
        Issue.record("Field search did not settle")
    }
    private func ownDatabase(_ root:URL, bible:Bool) throws -> LibraryResource {
        let url=root.appendingPathComponent(bible ? "Owned.bbli":"Owned.refi");var db:OpaquePointer?
        #expect(sqlite3_open(url.path,&db) == SQLITE_OK);defer{sqlite3_close(db)}
        let payload=bible ? "CREATE TABLE Bible(Book,Chapter,Verse,Scripture);INSERT INTO Bible VALUES(43,3,16,'😀 faith'),(43,3,17,'hope'),(43,3,18,'faith hope');" : "CREATE TABLE Reference(Chapter,Content);INSERT INTO Reference VALUES('OwnedTitle','betaBody'),('OtherTitle','otherBody');"
        #expect(sqlite3_exec(db,"CREATE TABLE Details(Title,Abbreviation,Information);INSERT INTO Details VALUES('Owned field resource','F','Fixture');"+payload,nil,nil,nil) == SQLITE_OK)
        return try ESwordResource.inspect(url)
    }
    @Test func visibleNotesAndSharedArticleTitlesKeepIndependentFieldsAndExactOpeningCoordinates() async throws {
        _=NSApplication.shared
        let html="<span id='a1'></span><h1 epub:type='fulltitle'>DeclaredTitle</h1><p>BodyOnly</p><aside role='doc-footnote'>NoteOnly</aside><span id='a2'></span><h2>SecondHeading</h2><p>OtherBody</p><aside epub:type='footnote'>OtherNote</aside>"
        let fixture=try AuthoredOEBFixture(chapterBody:html);defer{fixture.remove()}
        let provider=PersistentLibrarySearchProvider(source:WorkspaceSearchReader(),directory:fixture.root.appendingPathComponent("cache")),service=LibrarySearchService(provider:provider)
        let note=try await service.search(resources:[fixture.resource],query:SearchQueryParser.parse("footnote:OtherNote"))
        #expect(note.coverageComplete && note.results.count == 1 && note.results[0].sectionOrdinal == 2)
        let reader=ReaderSession(resource:fixture.resource);reader.loadSearchResult(note.results[0]);try await settle{!reader.isLoading}
        let page=try #require(reader.page?.oeb),path=try #require(page.book.path(for:page.url))
        let projection=try await ReaderOEBTextSource.shared.read(book:page.book,path:path,viewport:.init())
        try reader.acceptOEBProjection(projection.text,at:page.url)
        #expect(reader.error == nil && reader.selectedText == "OtherNote")
        let title=try await service.search(resources:[fixture.resource],query:SearchQueryParser.parse("title:Second"))
        #expect(title.coverageComplete && title.results.count == 1 && title.results[0].sectionOrdinal == 2 && title.results[0].hits.isEmpty && title.results[0].externalHits.count == 1)
        for (query,count) in [("title:DeclaredTitle",1),("body:NoteOnly",0),("heading:SecondHeading",1),("footnote:BodyOnly",0)] {
            let result=try await service.search(resources:[fixture.resource],query:SearchQueryParser.parse(query))
            #expect(result.coverageComplete && result.results.count == count)
        }
        let reopened=LibrarySearchService(provider:PersistentLibrarySearchProvider(source:WorkspaceSearchReader(),directory:fixture.root.appendingPathComponent("cache")))
        #expect(try await reopened.search(resources:[fixture.resource],query:SearchQueryParser.parse("footnote:OtherNote")).results == note.results)
    }
    @Test func openingNoteResultAppliesSelectionToTheActualWebViewAfterNavigation() async throws {
        _ = NSApplication.shared
        let fixture = try AuthoredOEBFixture(chapterBody: "<span id='a1'></span><p>BodyOnly</p><aside role='doc-footnote'>NoteOnly</aside><span id='a2'></span><p>OtherBody</p>")
        defer { fixture.remove() }
        let report = try await LibrarySearchService(provider: WorkspaceSearchReader()).search(resources: [fixture.resource], query: SearchQueryParser.parse("footnote:NoteOnly"))
        let reader = ReaderSession(resource: fixture.resource)
        reader.loadSearchResult(try #require(report.results.first))
        try await settle { !reader.isLoading }
        let coordinator = ReaderOEBView.Coordinator(reader: reader, activate: {})
        let view = ReaderOEBView.makeWebView(reader: reader, coordinator: coordinator)
        view.setFrameSize(NSSize(width: 760, height: 900))
        defer {
            view.stopLoading(); view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
            reader.cancel()
        }
        coordinator.begin(try #require(reader.page?.oeb), in: view)
        try await settle { coordinator.ready }
        #expect(reader.error == nil && reader.selectedText == "NoteOnly")
        // No test-side selection call: navigation must deliver the pending range.
        var selected: String?
        for _ in 0..<100 {
            selected = try await view.callAsyncJavaScript("return getSelection().toString();", in: nil, contentWorld: .defaultClient) as? String
            if selected == "NoteOnly" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(selected == "NoteOnly")
    }
    @Test func rawAndNormalizedSQLiteTitlesMatchMetadataWithoutInventingBodyRanges() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let raw=try ownDatabase(root,bible:false),bytes=try Data(contentsOf:raw.location)
        let package=try LibronPackage.create(raw,in:root.appendingPathComponent("library"),backup:false)
        let native=try LibronPackage.read(package).1;_=try await LibronNativeNormalizer().convert(native)
        for resource in [raw,native] {
            let search=WorkspaceSearchController();search.resourceID=resource.id;search.searchField = .title;search.query="OwnedTitle"
            search.run([resource]);try await settle{!search.isSearching}
            let result=try #require(search.report?.results.first)
            #expect(search.error == nil && search.coverageComplete && result.hitCount == 1 && result.hits.isEmpty && result.externalHits[0].value == "OwnedTitle")
            let reader=ReaderSession(resource:resource);reader.loadSearchResult(result);try await settle{!reader.isLoading}
            #expect(reader.error == nil && reader.selectedRange.length == 0 && reader.page?.text.contains("betaBody") == true)
            search.searchField = .body;search.query="OwnedTitle";search.run([resource]);try await settle{!search.isSearching}
            #expect(search.coverageComplete && search.report?.results.isEmpty == true)
            search.query="betaBody";search.run([resource]);try await settle{!search.isSearching};#expect(search.coverageComplete && search.report?.results.count == 1)
            search.searchField = .footnote;search.query="NOT absent";search.run([resource]);try await settle{!search.isSearching}
            #expect(!search.coverageComplete && search.report?.results.isEmpty == true && search.report?.counters.resourcesIncompatible == 1 && search.report?.counters.articlesExamined == 0)
        }
        #expect(try Data(contentsOf:raw.location) == bytes)
    }
    @Test func BibleBodyFieldsExcludeDisplayNumbersAndPreserveProximityAcrossSourceVerses() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let raw=try ownDatabase(root,bible:true),bytes=try Data(contentsOf:raw.location)
        let package=try LibronPackage.create(raw,in:root.appendingPathComponent("library"),backup:false)
        let native=try LibronPackage.read(package).1;_=try await LibronNativeNormalizer().convert(native)
        for resource in [raw,native] {
            let search=WorkspaceSearchController();search.resourceID=resource.id;search.searchField = .body;search.query="16"
            search.run([resource]);try await settle{!search.isSearching};#expect(search.coverageComplete && search.report?.results.isEmpty == true)
            search.query="faith BEFORE/0 hope";search.run([resource]);try await settle{!search.isSearching}
            #expect(search.error == nil && search.coverageComplete && search.report?.results.first?.hitCount == 4)
            search.searchField = .bibleText;search.query="faith WITHIN 1 VERSES hope";search.run([resource]);try await settle{!search.isSearching}
            #expect(search.coverageComplete && search.report?.results.first?.hitCount == 4)
            search.bibleVerses=true;search.bibleRangeMode = .custom;search.customBibleRange="John3:16–17";search.run([resource]);try await settle{!search.isSearching}
            #expect(search.coverageComplete && search.report?.results.isEmpty == true && search.report?.counters.versesExamined == 2)
        }
        #expect(try Data(contentsOf:raw.location) == bytes)
    }
    @Test func manualCollectionsAndMixedSupportRemainBoundedAndSourceSpecific() async throws {
        _=NSApplication.shared
        let fixture=try AuthoredReaderFixture(documents:[["faith"]]);defer{fixture.remove()}
        let html=try AuthoredOEBFixture(chapterBody:"<span id='a1'></span><p>BodyOnly</p><aside role='doc-footnote'>NoteOnly</aside><span id='a2'></span><p>OtherBody</p>");defer{html.remove()}
        let store=LibraryCollections(url:fixture.root.appendingPathComponent("collections.json")),id=try store.create()
        try store.add([fixture.resources[0],html.resource],to:id)
        let search=WorkspaceSearchController();search.scope.kind = .collections;search.scope.collectionIDs=[id];search.searchField = .footnote;search.query="NoteOnly"
        search.run(fixture.resources+[html.resource],scopeContext:.init(library:fixture.resources+[html.resource],collections:store.sets));try await settle{!search.isSearching}
        #expect(search.error == nil && !search.coverageComplete && search.report?.results.map(\.resourceID) == [html.resource.id] && search.report?.counters.resourcesIncompatible == 1)
        search.scope.kind = .resource;search.resourceID=html.resource.id;search.query="title:Chapter"
        search.run([html.resource]);#expect(search.error?.contains("field clauses") == true && search.report == nil)

    }
}
