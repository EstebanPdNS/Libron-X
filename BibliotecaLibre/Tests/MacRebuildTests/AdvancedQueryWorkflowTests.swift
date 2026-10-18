import AppKit
import Foundation
import Testing
import CSQLite
import LibronixCore
@testable import MacRebuild

@Suite(.serialized) @MainActor struct AdvancedQueryWorkflowTests {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() {return};try await Task.sleep(for:.milliseconds(5)) }
        Issue.record("Advanced query did not settle")
    }
    @Test func legacyCollectionQueryHighlightsOnlyWitnessesAndRejectsAmbiguousSyntax() async throws {
        _=NSApplication.shared
        let fixture=try AuthoredReaderFixture(documents:[["😀 faith one hope faith far far hope"],["faith hope"]]);defer{fixture.remove()}
        let collections=LibraryCollections(url:fixture.root.appendingPathComponent("collections.json")),id=try collections.create()
        try collections.add(fixture.resources[0],to:id)
        let workspace=StudyWorkspace(personal:.init(url:fixture.root.appendingPathComponent("personal.json")),resourceVisibility:.init(url:fixture.root.appendingPathComponent("visibility.json")),parallelBibleSets:.init(url:fixture.root.appendingPathComponent("bibles.json")),collections:collections)
        workspace.resources=fixture.resources
        let search=workspace.search;search.scope.kind = .collections;search.scope.collectionIDs=[id];search.query="faith BEFORE/1 hope"
        search.run(workspace.resources,scopeContext:workspace.searchScopeContext());try await settle{!search.isSearching}
        let result=try #require(search.report?.results.first)
        #expect(search.coverageComplete && search.report?.results.count == 1 && result.hitCount == 2)
        workspace.openSearchResult(result,scope:search.scopeSnapshot)
        let reader=try #require(workspace.activeReader);try await settle{!reader.isLoading}
        #expect(reader.selectedText == "faith" && reader.selectedRange.location == 3)
        search.query="faith BEFORE (hope AND far)";search.run(workspace.resources,scopeContext:workspace.searchScopeContext())
        #expect(search.error != nil && search.report == nil)
        workspace.closeAll()
    }
    @Test func rawAndNormalizedBiblesPreserveDistancesVerseRangesAndOpeningCoordinates() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("Owned.bbli");var db:OpaquePointer?
        #expect(sqlite3_open(url.path,&db) == SQLITE_OK)
        #expect(sqlite3_exec(db,"CREATE TABLE Details(Title,Abbreviation,Information);INSERT INTO Details VALUES('Owned proximity','P','Fixture');CREATE TABLE Bible(Book,Chapter,Verse,Scripture);INSERT INTO Bible VALUES(43,3,16,'😀 faith'),(43,3,17,'hope'),(43,3,18,'faith hope');",nil,nil,nil) == SQLITE_OK);sqlite3_close(db)
        let raw=try ESwordResource.inspect(url),before=try Data(contentsOf:url)
        let package=try LibronPackage.create(raw,in:root.appendingPathComponent("library"),backup:false)
        let native=try LibronPackage.read(package).1;_=try await LibronNativeNormalizer().convert(native)
        for resource in [raw,native] {
            let search=WorkspaceSearchController();search.resourceID=resource.id;search.query="faith WITHIN 1 VERSES hope"
            search.run([resource]);try await settle{!search.isSearching}
            #expect(search.error == nil && search.coverageComplete && search.report?.results.count == 1 && search.report?.results[0].hitCount == 4)
            let result=try #require(search.report?.results.first),reader=ReaderSession(resource:resource)
            reader.loadSearchResult(result);try await settle{!reader.isLoading}
            #expect(reader.error == nil && reader.selectedText == "faith")
            search.bibleVerses=true;search.bibleRangeMode = .custom;search.customBibleRange="John3:16–17"
            search.run([resource]);try await settle{!search.isSearching}
            #expect(search.coverageComplete && search.report?.results.isEmpty == true && search.report?.counters.versesExamined == 2)
            search.customBibleRange="John3:18";search.run([resource]);try await settle{!search.isSearching}
            #expect(search.coverageComplete && search.report?.results.count == 1 && search.report?.results[0].bibleReference == "jn 3:18")
        }
        #expect(try Data(contentsOf:url) == before)
    }
}
