import Foundation
import Testing
import CSQLite
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct KeyLinkControllerTests {
    private func database(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path,&db) == SQLITE_OK else { throw RebuildError.unsupportedFormat }
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK)
    }
    private func dictionary(_ root: URL, name: String, lexicon: Bool = false, missing: Bool = false) throws -> LibraryResource {
        let url = root.appendingPathComponent(name+".sqlite")
        try database(url,sql:"PRAGMA user_version=1; CREATE TABLE entries(ordinal INTEGER PRIMARY KEY,headword TEXT,body TEXT); CREATE TABLE lookup(key TEXT,ordinal INTEGER); INSERT INTO entries VALUES(0,'Verbo','😀 Verbo: authored definition'),(1,'λόγος','λόγος: authored Greek'); INSERT INTO lookup VALUES('λόγος',1);" + (missing ? "" : "INSERT INTO lookup VALUES('verbo',0);"))
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path,&handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle,"UPDATE lookup SET key=? WHERE ordinal=1",-1,&statement,nil) == SQLITE_OK)
        _ = LibronDictionaryIndex.key("λόγος").withCString { sqlite3_bind_text(statement,1,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(statement) == SQLITE_DONE);sqlite3_finalize(statement)
        var metadata = LibronMetadata(title:name,origin:"Fixture");metadata.resourceType = lexicon ? "Léxico" : "Diccionario o enciclopedia";metadata.languages = lexicon ? ["el"] : ["es"]
        return .init(location:url,title:name,byteCount:0,format:.libronDictionary,support:.metadataOnly,provenance:.fileName,libron:metadata)
    }
    private func workspace(_ root: URL) -> StudyWorkspace {
        .init(personal:.init(url:root.appendingPathComponent("personal.json")),
              resourceVisibility:.init(url:root.appendingPathComponent("visibility.json")),
              parallelBibleSets:.init(url:root.appendingPathComponent("parallel.json")),
              collections:.init(url:root.appendingPathComponent("collections.json")),
              resourcePriorities:.init(url:root.appendingPathComponent("priorities.json")))
    }
    private func settle(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return };try await Task.sleep(for:.milliseconds(5)) }
        Issue.record("KeyLink workflow did not settle")
    }
    @Test func realDictionaryAndLexiconDestinationsPreserveExactUnicodeAndRejectChangedSources() async throws {
        let fixture = try AuthoredReaderFixture(documents:[["Source"]]);defer { fixture.remove() }
        let dict = try dictionary(fixture.root,name:"Dictionary"), lex = try dictionary(fixture.root,name:"Lexicon",lexicon:true)
        let before = try Data(contentsOf:dict.location)
        let match = try #require(try await KeyLinkController.resolve(dict,scope:.init(kind:.dictionary,language:"es"),query:"VERBO"))
        #expect(match.label == "Verbo" && match.destination.ordinal == 0 && match.page.text.hasPrefix("😀"))
        #expect(try await KeyLinkController.resolve(dict,scope:.init(kind:.dictionary),query:"unknown") == nil)
        let greek = try #require(try await KeyLinkController.resolve(lex,scope:.init(kind:.lexicon,language:"el"),query:"λόγος"))
        #expect(greek.destination.ordinal == 1 && greek.page.text.contains("Greek"))
        #expect(try await KeyLinkController.resolve(lex,scope:.init(kind:.dictionary),query:"λόγος") == nil)
        let value = workspace(fixture.root);value.resources = [dict,lex]
        value.openKeyLink(match);try await settle { value.readers.first?.isLoading == false }
        #expect(value.readers.first?.page?.text == match.page.text && value.readers.first?.error == nil)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(30)],ofItemAtPath:dict.location.path)
        value.openKeyLink(match)
        #expect(value.readers.count == 1 && value.error != nil)
        #expect(try Data(contentsOf:dict.location) == before)
    }
    @Test func BibleAndCommentaryQueriesResolveRealReferenceAnchorsInRawAndNormalizedContent() async throws {
        let fixture = try AuthoredReaderFixture(documents:[["Source"]]);defer { fixture.remove() }
        let bibleURL = fixture.root.appendingPathComponent("bible.bbli"), commentURL = fixture.root.appendingPathComponent("comment.cmti")
        let details = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Fixture','F','Owned fixture');"
        try database(bibleURL,sql:details+"CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'😀 First'),(1,1,2,'Second');")
        try database(commentURL,sql:details+"CREATE TABLE BookCommentary(Book,Comments); CREATE TABLE ChapterCommentary(Book,Chapter,Comments); CREATE TABLE VerseCommentary(Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd,Comments); INSERT INTO VerseCommentary VALUES(1,1,1,1,1,'😀 Owned commentary');")
        let original = try [bibleURL,commentURL].map { try Data(contentsOf:$0) }
        for (url,kind) in [(bibleURL,KeyLinkKind.bible),(commentURL,KeyLinkKind.commentary)] {
            let raw = try ESwordResource.inspect(url)
            #expect(kind.supports(raw))
            for normalized in [false,true] {
                let resource: LibraryResource
                if normalized {
                    let package = try LibronPackage.create(raw,in:fixture.root.appendingPathComponent("library"),backup:false)
                    resource = try LibronPackage.read(package).1;_ = try await LibronNativeNormalizer().convert(resource)
                } else { resource = raw }
                let found = try #require(try await KeyLinkController.resolve(resource,scope:.init(kind:kind),query:"Ge 1:1"))
                #expect(kind == .commentary ? found.destination.reference == nil : found.destination.reference?.lowercased() == "ge 1:1")
                #expect(found.page.text.contains(kind == .bible ? "First" : "commentary"))
                #expect(try await KeyLinkController.resolve(resource,scope:.init(kind:kind),query:"Ge 9:99") == nil)
            }
        }
        #expect(try [bibleURL,commentURL].map { try Data(contentsOf:$0) } == original)
    }
    @Test func preferredOpeningFallsThroughMissingAndFailedCandidatesAndHonorsWindowCount() async throws {
        let fixture = try AuthoredReaderFixture(documents:[["Source"]]);defer { fixture.remove() }
        let missing = try dictionary(fixture.root,name:"Missing",missing:true), failed = try dictionary(fixture.root,name:"Failed"), good = try dictionary(fixture.root,name:"Good"), other = try dictionary(fixture.root,name:"Other")
        try Data("corrupt sqlite".utf8).write(to:failed.location)
        let value = workspace(fixture.root);value.resources = [good,other,missing,failed]
        let scope = KeyLinkScope(kind:.dictionary)
        for resource in [failed,missing,other,good] { try value.resourcePriorities.promote(resource,in:scope) }
        try value.resourcePriorities.setOpenCount(2,in:scope)
        let controller = value.keyLinks;controller.scope = scope;controller.query = "Verbo"
        controller.run(workspace:value,openPreferred:true);try await settle { controller.completed }
        #expect(controller.results.map(\.id) == [other.id,good.id] && controller.examined == 4 && controller.failures.count == 1)
        try await settle { value.readers.allSatisfy { !$0.isLoading } }
        #expect(value.readers.count == 2 && value.readers.allSatisfy { $0.page?.text.contains("authored definition") == true && $0.error == nil })
        controller.query = "NoMatchFixture";controller.run(workspace:value);try await settle { controller.completed }
        #expect(controller.results.isEmpty && controller.failures.count == 1 && value.readers.count == 2)
        try value.resourcePriorities.setEnabled(false,resources:[good,other],in:scope)
        controller.query = "Verbo";controller.run(workspace:value);try await settle { controller.completed }
        #expect(controller.results.isEmpty && controller.examined == 2)
        controller.query = "Ge 1:1";controller.scope = .init(kind:.bible);controller.run(workspace:value);try await settle { controller.completed }
        #expect(controller.results.isEmpty && controller.examined == 0)
    }
    @Test func automaticDictionaryLookupUsesPrioritiesButExplicitDictionaryStillWins() async throws {
        let fixture = try AuthoredReaderFixture(documents:[["Source"]]);defer { fixture.remove() }
        let a = try dictionary(fixture.root,name:"A dictionary"), b = try dictionary(fixture.root,name:"B dictionary")
        let value = workspace(fixture.root);value.resources = [a,b]
        let scope = KeyLinkScope(kind:.dictionary)
        try value.resourcePriorities.promote(b,in:scope)
        value.dictionary.lookup("Verbo",workspace:value);try await settle { !value.dictionary.isLoading }
        #expect(value.dictionary.resourceID == b.id && value.dictionary.page != nil)
        try value.resourcePriorities.setEnabled(false,resources:[b],in:scope)
        value.dictionary.lookup("Verbo",workspace:value);try await settle { !value.dictionary.isLoading }
        #expect(value.dictionary.resourceID == a.id)
        value.dictionary.lookup("Verbo",workspace:value,preferredID:b.id);try await settle { !value.dictionary.isLoading }
        #expect(value.dictionary.resourceID == b.id && value.dictionary.page != nil)
    }
    @Test func cancellationAndSupersedingQueriesCannotPublishOrOpenLateResults() async throws {
        let fixture = try AuthoredReaderFixture(documents:[["Source"]]);defer { fixture.remove() }
        let dict = try dictionary(fixture.root,name:"Dictionary"), value = workspace(fixture.root)
        value.resources = [dict]
        let controller = KeyLinkController { resource, _, query in
            if query == "slow" { try? await Task.sleep(for:.milliseconds(150)) }
            return .init(resource:resource,destination:.init(ordinal:0),label:query,page:.init(destination:.init(ordinal:0),text:query,sectionCount:1),stamps:[])
        }
        controller.query = "slow";controller.run(workspace:value,openPreferred:true);await Task.yield();controller.cancel()
        try await Task.sleep(for:.milliseconds(200))
        #expect(controller.results.isEmpty && !controller.completed && value.readers.isEmpty)
        controller.query = "slow";controller.run(workspace:value);await Task.yield()
        controller.query = "fast";controller.run(workspace:value);try await settle { controller.completed }
        try await Task.sleep(for:.milliseconds(200))
        #expect(controller.results.map(\.label) == ["fast"] && controller.failures.isEmpty)
        let cancelledSource = KeyLinkController { _, _, _ in throw CancellationError() }
        cancelledSource.query = "word";cancelledSource.run(workspace:value)
        try await settle { !cancelledSource.isLoading }
        #expect(!cancelledSource.completed && cancelledSource.results.isEmpty)
        controller.scope = .init(kind:.bible);controller.query = "invalid reference";controller.run(workspace:value)
        #expect(controller.completed && controller.failures.count == 1 && controller.results.isEmpty)
        controller.scope = .init(kind:.dictionary);controller.query = "bad\0word";controller.run(workspace:value)
        #expect(!controller.isLoading && !controller.completed && controller.results.isEmpty)
    }
}
