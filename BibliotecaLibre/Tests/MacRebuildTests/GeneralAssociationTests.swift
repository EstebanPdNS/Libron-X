import Foundation
import Testing
import CSQLite
@testable import LibronixCore
@testable import MacRebuild

private actor AssociationMatchGate {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func hold() async { calls += 1; await withCheckedContinuation { waiting.append($0) } }
    func release() { let pending = waiting; waiting = []; for continuation in pending { continuation.resume() } }
}
@MainActor struct GeneralAssociationTests {
    private func series(_ resource: LibraryResource) -> LibraryResource {
        var m = LibronMetadata.deriving(resource); m.collection = "Owned Series"; m.resourceType = "Monografía"
        return .init(location:resource.location,title:resource.title,byteCount:resource.byteCount,format:resource.format,
                     support:resource.support,provenance:resource.provenance,libron:m)
    }
    private func workspace(_ root: URL, resources: [LibraryResource]) -> StudyWorkspace {
        let w = StudyWorkspace(personal:.init(url:root.appendingPathComponent("personal.json")),
            resourceVisibility:.init(url:root.appendingPathComponent("hidden.json")),recentWorkspaces:.init(url:root.appendingPathComponent("recent.json")),
            parallelBibleSets:.init(url:root.appendingPathComponent("bibles.json")),collections:.init(url:root.appendingPathComponent("collections.json")),
            resourcePriorities:.init(url:root.appendingPathComponent("priorities.json")),resourceAssociations:.init(url:root.appendingPathComponent("associations.json")))
        w.resources = resources; return w
    }
    private func group(_ w: StudyWorkspace, scope: AssociationResourceScope = .init(kind:.series,series:"Owned Series"), relation: AssociationRelation = .alternatives) throws -> ResourceAssociationSet {
        let id = try w.resourceAssociations.create()
        try w.resourceAssociations.configure(id,name:"Owned",relation:relation,scope:scope,resources:w.resources)
        try w.resourceAssociations.add(w.resources,to:id)
        return try #require(w.resourceAssociations.sets.first { $0.id == id })
    }
    private func ready(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(2)) }
        #expect(condition())
    }
    private func gateReady(_ gate: AssociationMatchGate) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while await gate.calls == 0 && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(2)) }
        #expect(await gate.calls > 0)
    }
    private func database(_ url: URL, sql: String) throws {
        var db: OpaquePointer?; #expect(sqlite3_open(url.path,&db) == SQLITE_OK); defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK)
    }
    @Test func seriesAlternativeUsesTargetsOwnBeginningAndRetainsPaneGeometry() async throws {
        let f = try AuthoredReaderFixture(documents:[["Source zero","Source later"],["Target zero","Target later"]]); defer { f.remove() }
        let resources = f.resources.map(series), w = workspace(f.root,resources:resources), g = try group(w)
        let source = w.open(resources[0],destination:.init(ordinal:1)); try await ready { !source.isLoading }
        source.textScale = 1.5; source.frame = .init(x:0.1,y:0.1,width:0.5,height:0.6)
        let id = source.id, frame = source.frame, before = try resources.map { try Data(contentsOf:$0.location) }
        w.beginAssociatedResources(groupID:g.id,source:source)
        w.associationNavigation.open(g.members[1],workspace:w); try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error == nil && w.readers.count == 1 && w.activeID == id)
        #expect(source.id == id && source.resource == resources[1] && source.page?.destination.ordinal == 0)
        #expect(source.page?.text.contains("Target zero") == true && source.frame == frame && source.textScale == 1.5)
        #expect(source.history.count == 1 && source.historyIndex == 0 && source.parallelSetID == nil && source.linkGroup == .none)
        #expect(try resources.map { try Data(contentsOf:$0.location) } == before)
    }
    @Test func companionAndExplicitNewReaderPreserveSource() async throws {
        let f = try AuthoredReaderFixture(documents:[["one"],["two"]]); defer { f.remove() }
        let resources = f.resources.map(series), w = workspace(f.root,resources:resources)
        let source = w.open(resources[0]); try await ready { !source.isLoading }; source.textScale = 1.25
        let original = source.page?.text, history = source.history
        for relation in [AssociationRelation.companions,.alternatives] {
            let g = try group(w,relation:relation)
            w.beginAssociatedResources(groupID:g.id,source:source)
            w.associationNavigation.open(g.members[1],workspace:w,newReader:relation == .alternatives)
            try await ready { !w.associationNavigation.isLoading }
            #expect(w.associationNavigation.error == nil && w.activeReader?.resource == resources[1])
            #expect(w.activeReader?.textScale == 1.25 && source.resource == resources[0])
            #expect(source.page?.text == original && source.history == history)
        }
        #expect(w.readers.count == 3)
    }
    @Test func commentaryReferenceResolvesDifferentPhysicalOrdinalWithoutBibleRelabelling() async throws {
        let f = try AuthoredReaderFixture(documents:[["source"]]); defer { f.remove() }
        let details = "CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Owned commentary','C','Owned'); CREATE TABLE BookCommentary(Book,Comments); CREATE TABLE ChapterCommentary(Book,Chapter,Comments); CREATE TABLE VerseCommentary(Book,ChapterBegin,VerseBegin,ChapterEnd,VerseEnd,Comments);"
        let a = f.root.appendingPathComponent("a.cmti"), b = f.root.appendingPathComponent("b.cmti")
        try database(a,sql:details+"INSERT INTO VerseCommentary VALUES(1,1,1,1,1,'Source Ge1:1');")
        try database(b,sql:details+"INSERT INTO VerseCommentary VALUES(1,1,1,1,1,'Target Ge1:1'),(1,1,2,1,2,'Target Ge1:2');")
        let resources = try [a,b].map(ESwordResource.inspect), w = workspace(f.root,resources:resources)
        let g = try group(w,scope:.init(kind:.commentary))
        let source = w.open(resources[0]); try await ready { !source.isLoading }
        w.beginAssociatedResources(groupID:g.id,source:source); w.associationNavigation.mode = .reference; w.associationNavigation.query = "Ge 1:2"
        w.associationNavigation.open(g.members[1],workspace:w); try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error == nil && source.resource == resources[1])
        #expect(source.page?.text.contains("Target Ge1:2") == true && source.page?.destination.ordinal == 1)
        #expect(source.page?.content?.anchors.isEmpty == true && source.canSynchronizeBible == false)
        let text = source.page?.text, history = source.history
        w.beginAssociatedResources(groupID:g.id,source:source); w.associationNavigation.mode = .reference; w.associationNavigation.query = "Ge 9:99"
        w.associationNavigation.open(g.members[0],workspace:w); try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error != nil && source.page?.text == text && source.history == history)
    }
    @Test func lexiconHeadwordUsesIndependentTargetLookupOrdinalAndLabel() async throws {
        let f = try AuthoredReaderFixture(documents:[["source"]]); defer { f.remove() }
        var resources: [LibraryResource] = []
        for i in 0..<2 {
            let url = f.root.appendingPathComponent("lexicon\(i).sqlite")
            let key = LibronDictionaryIndex.key("λόγος")
            try database(url,sql:"PRAGMA user_version=1; CREATE TABLE entries(ordinal INTEGER PRIMARY KEY,headword TEXT,body TEXT); CREATE TABLE lookup(key TEXT,ordinal INTEGER); INSERT INTO entries VALUES(0,'first','first definition'),(1,'λόγος','Owned Greek target \(i)'); INSERT INTO lookup VALUES('\(key)',1);")
            var m = LibronMetadata(title:"Lexicon \(i)",origin:"Fixture");m.resourceType="Léxico";m.languages=["el"]
            resources.append(.init(location:url,title:m.title,byteCount:0,format:.libronDictionary,support:.metadataOnly,provenance:.fileName,libron:m))
        }
        let w = workspace(f.root,resources:resources), g = try group(w,scope:.init(kind:.lexicon,language:"el"))
        let source = w.open(resources[0]); try await ready { !source.isLoading }
        w.beginAssociatedResources(groupID:g.id,source:source);w.associationNavigation.mode = .headword;w.associationNavigation.query="λόγος"
        w.associationNavigation.open(g.members[1],workspace:w);try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error == nil && source.resource == resources[1])
        #expect(source.page?.destination.ordinal == 1 && source.page?.text.contains("Owned Greek target 1") == true)
        #expect(source.dictionaryWord == "λόγος" && source.locator == "λόγος")
    }
    @Test func unsupportedCoordinateAndMissingResourceLeaveOriginalReadingIntact() async throws {
        let f = try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let resources=f.resources.map(series),w=workspace(f.root,resources:resources),g=try group(w)
        let source=w.open(resources[0]);try await ready { !source.isLoading };let text=source.page?.text,history=source.history
        w.beginAssociatedResources(groupID:g.id,source:source);w.associationNavigation.mode = .headword;w.associationNavigation.query="word"
        w.associationNavigation.open(g.members[1],workspace:w);try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error != nil && source.resource == resources[0] && source.page?.text == text)
        try w.hideLibraryResources([resources[1].id]);w.associationNavigation.mode = .start
        w.associationNavigation.open(g.members[1],workspace:w)
        #expect(w.associationNavigation.error != nil && source.history == history && w.readers.count == 1)
    }
    @Test func editedOrDeletedGroupDuringLookupCannotCommitAndDoesNotStayBusy() async throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let resources=f.resources.map(series),w=workspace(f.root,resources:resources),g=try group(w),gate=AssociationMatchGate()
        w.associationNavigation = .init(lookup: { resource,scope,mode,query in
            let result=try await AssociationNavigationController.resolve(resource,scope:scope,mode:mode,query:query)
            await gate.hold();return result
        })
        let source=w.open(resources[0]);try await ready { !source.isLoading }
        w.beginAssociatedResources(groupID:g.id,source:source);w.associationNavigation.open(g.members[1],workspace:w)
        try await gateReady(gate);try w.resourceAssociations.remove(g.id);await gate.release()
        try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error != nil && source.resource == resources[0] && w.readers.count == 1)
    }
    @Test(arguments:[false,true]) func sourceNavigationOrClosureDuringLookupCannotCommit(close:Bool) async throws {
        let f=try AuthoredReaderFixture(documents:[["a","later"],["b"]]);defer { f.remove() }
        let resources=f.resources.map(series),w=workspace(f.root,resources:resources),g=try group(w),gate=AssociationMatchGate()
        w.associationNavigation = .init(lookup: { resource,scope,mode,query in
            let result=try await AssociationNavigationController.resolve(resource,scope:scope,mode:mode,query:query)
            await gate.hold();return result
        })
        let source=w.open(resources[0]);try await ready { !source.isLoading }
        w.beginAssociatedResources(groupID:g.id,source:source);w.associationNavigation.open(g.members[1],workspace:w)
        try await gateReady(gate)
        if close { w.close(source) } else { source.load(.init(ordinal:1));try await ready { !source.isLoading } }
        await gate.release();try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error != nil && source.resource == resources[0])
        #expect(w.readers.count == (close ? 0 : 1))
    }
    @Test func targetMutationAfterLookupIsRejectedBeforeAnyPaneChanges() async throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let resources=f.resources.map(series),w=workspace(f.root,resources:resources),g=try group(w),gate=AssociationMatchGate()
        w.associationNavigation = .init(lookup: { resource,scope,mode,query in
            let result=try await AssociationNavigationController.resolve(resource,scope:scope,mode:mode,query:query)
            await gate.hold();return result
        })
        let source=w.open(resources[0]);try await ready { !source.isLoading };let text=source.page?.text
        w.beginAssociatedResources(groupID:g.id,source:source);w.associationNavigation.open(g.members[1],workspace:w,newReader:true)
        try await gateReady(gate);var bytes=try Data(contentsOf:resources[1].location);bytes.append(0);try bytes.write(to:resources[1].location)
        await gate.release();try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error != nil && w.readers.count == 1 && source.page?.text == text)
    }
    @Test func cancelledOrSupersededLookupCannotOpenLateResults() async throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let resources=f.resources.map(series),w=workspace(f.root,resources:resources),g=try group(w),gate=AssociationMatchGate()
        w.associationNavigation = .init(lookup: { resource,scope,mode,query in
            let result=try await AssociationNavigationController.resolve(resource,scope:scope,mode:mode,query:query)
            await gate.hold();return result
        })
        let source=w.open(resources[0]);try await ready { !source.isLoading }
        w.beginAssociatedResources(groupID:g.id,source:source);w.associationNavigation.open(g.members[1],workspace:w)
        try await gateReady(gate);w.associationNavigation.cancel();w.associationNavigation.mode = .headword;w.associationNavigation.query="new"
        await gate.release();try await Task.sleep(for:.milliseconds(20))
        #expect(!w.associationNavigation.isLoading && w.associationNavigation.error == nil && source.resource == resources[0] && w.readers.count == 1)
    }
    @Test func automaticBibleContextPreservesReferenceAndExistingBibleSetDefinitions() async throws {
        let f=try AuthoredReaderFixture(documents:[["owned"]]);defer { f.remove() }
        var resources:[LibraryResource]=[]
        for i in 0..<2 {
            let url=f.root.appendingPathComponent("bible\(i).bbli")
            try database(url,sql:"CREATE TABLE Details(Title,Abbreviation,Information); INSERT INTO Details VALUES('Bible','B','Owned'); CREATE TABLE Bible(Book,Chapter,Verse,Scripture); INSERT INTO Bible VALUES(1,1,1,'First \(i)'),(1,1,2,'Second \(i)');")
            resources.append(try ESwordResource.inspect(url))
        }
        let w=workspace(f.root,resources:resources),g=try group(w,scope:.init(kind:.bible))
        let bibleSet=try w.parallelBibleSets.create();for r in resources { try w.parallelBibleSets.add(r,to:bibleSet) }
        let bytes=try Data(contentsOf:f.root.appendingPathComponent("bibles.json"))
        let source=w.open(resources[0],destination:.init(ordinal:0,reference:"Ge 1:2"));try await ready { !source.isLoading }
        source.parallelSetID=bibleSet;w.referenceTargetID=source.id
        let reference=try #require(source.currentReference)
        w.beginAssociatedResources(groupID:g.id,source:source)
        #expect(w.associationNavigation.mode == .reference && w.associationNavigation.query == reference)
        w.associationNavigation.open(g.members[1],workspace:w);try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error == nil && source.resource == resources[1])
        #expect(source.currentReference == reference && source.page?.text.contains("Second 1") == true)
        #expect(source.parallelSetID == nil && w.referenceTargetID == source.id)
        #expect(try Data(contentsOf:f.root.appendingPathComponent("bibles.json")) == bytes)
    }
    @Test(arguments:[0,1,2]) func forgedLookupResourceStampsOrOrdinalCannotCommit(caseID:Int) async throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let resources=f.resources.map(series),w=workspace(f.root,resources:resources),g=try group(w)
        let wrong=resources[0]
        w.associationNavigation = .init(lookup: { resource,scope,mode,query in
            let m=try #require(try await AssociationNavigationController.resolve(resource,scope:scope,mode:mode,query:query))
            return .init(resource:caseID == 0 ? wrong : m.resource,
                destination:caseID == 2 ? .init(ordinal:99) : m.destination,label:m.label,page:m.page,
                stamps:caseID == 1 ? [try LibrarySearchFileStamp.capture(wrong.location)] : m.stamps)
        })
        let source=w.open(resources[0]);try await ready { !source.isLoading };let text=source.page?.text
        w.beginAssociatedResources(groupID:g.id,source:source);w.associationNavigation.open(g.members[1],workspace:w)
        try await ready { !w.associationNavigation.isLoading }
        #expect(w.associationNavigation.error != nil && source.resource == resources[0] && source.page?.text == text && w.readers.count == 1)
    }

}
