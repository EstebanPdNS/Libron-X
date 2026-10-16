import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct AssociatedTopicSearchTests {
    private func resource(_ name: String) -> LibraryResource {
        .init(location:URL(fileURLWithPath:"/authored/"+name),title:name,byteCount:0,format:.libronixLLS,support:.metadataOnly,provenance:.fileName)
    }
    private func catalog(_ fixture: AuthoredReaderFixture, stamp: Int = 1, dangling: Bool = false) throws -> LibronixTopicCatalog {
        let sections = try LegacyContentReader.inspectSections(lsfURL:fixture.resources[0].location)
        // Source row order is deliberately different from physical article IDs.
        let entries = [1,0].enumerated().map { row, id in
            LegacyArticleDirectoryEntry(directoryRow:row+90,articleID:UInt32(id),level:0,indexWithinLevel:UInt32(row),flags:0,
                relativeTartOffset:0,titleSegments:[.init(selectorCode:nil,text:"Owned \(id)")],positionLabel:nil,section:sections.sections[id])
        }
        let indexes = [LibronixNamedTopicIndex(name:"topics",stringEncoding:2,
            topics:[.init(text:"  Creación",referents:[1,0,1]),.init(text:"Recreación",referents:[0])],
            labelsByReferent:dangling ? [9:["Creación"]] : [1:["Creación"],0:["Creación","Recreación"]])]
        return try .init(indexes:indexes,directory:.init(entries:entries,sections:sections,namedPositionCount:0,warnings:[]),
            sourceStamp:.init(size:UInt64(stamp),modified:Date(timeIntervalSince1970:0),fileNumber:1))
    }
    private func settle(_ search: TopicSearchController) async throws {
        for _ in 0..<1000 { if !search.isLoading { return }; try await Task.sleep(for:.milliseconds(5)) }
        Issue.record("Associated topic request did not settle")
    }
    @Test func checkedArticleIDsAndPrefixQueriesNeverUseDirectoryRowsOrTitleSubstrings() throws {
        let fixture = try AuthoredReaderFixture(documents:[["Owned zero","Owned one"]]); defer {fixture.remove()}
        let source = try catalog(fixture)
        let matches = try source.matching(" CREA ",maximum:10)
        #expect(matches.count == 1 && matches[0].topic == 0)
        #expect(try source.matching("CREACION",maximum:10).count == 1)
        #expect(try source.matching("ación",maximum:10).isEmpty)
        #expect(try source.articles(index:0,topic:0).map(\.sectionOrdinal) == [1,0])
        #expect(try source.articles(index:0,topic:0).map(\.directoryRow) == [90,91])
        #expect(throws:LibronixTopicIndexFailure.malformed) {try source.articles(index:9,topic:0)}
        #expect(throws:LibronixTopicIndexFailure.malformed) {try catalog(fixture,dangling:true)}
    }
    @Test func selectingATopicProducesItsCheckedArticlesInTheOriginalOuterResource() async throws {
        let fixture = try AuthoredReaderFixture(documents:[["Owned zero","Owned one"]]); defer {fixture.remove()}
        let data = try catalog(fixture), first = resource("one.lbxlls"), second = resource("two.lbxlls")
        let search = TopicSearchController(topicLoader:{ _ in data },directoryLoader:{ _ in Issue.record("Title loader was used for associated topics"); return [] })
        search.search("crea",resources:[first,second],mode:.associated); try await settle(search)
        #expect(search.topics.count == 2 && search.entries.isEmpty && Set(search.topics.map(\.id)).count == 2)
        search.selectTopic(search.topics[1].id); try await settle(search)
        #expect(search.entries.map(\.entry.sectionOrdinal) == [1,0])
        #expect(search.entries.allSatisfy { $0.resource == second })
        search.selectTopic(nil)
        #expect(search.selectedTopicID == nil && search.entries.isEmpty)
        search.libraryDidChange()
        #expect(search.topics.isEmpty && search.status == .libraryChanged)
    }
    @Test func changedCatalogAndSpontaneousCancellationDoNotOpenStaleArticles() async throws {
        let fixture = try AuthoredReaderFixture(documents:[["Owned zero","Owned one"]]); defer {fixture.remove()}
        let original = try catalog(fixture), changed = try catalog(fixture,stamp:2), provider = CatalogSequence(original,changed)
        let search = TopicSearchController(topicLoader:{ _ in await provider.next() },directoryLoader:{ _ in [] })
        search.search("crea",resources:[resource("one.lbxlls")],mode:.associated); try await settle(search)
        search.selectTopic(try #require(search.topics.first?.id)); try await settle(search)
        #expect(search.entries.isEmpty && search.failures.count == 1 && !search.isLoading)
        let canceled = TopicSearchController(topicLoader:{ _ in throw CancellationError() },directoryLoader:{ _ in [] })
        canceled.search("crea",resources:[resource("one.lbxlls")],mode:.associated); try await settle(canceled)
        #expect(canceled.status == .canceled && canceled.topics.isEmpty && !canceled.isLoading)
    }
    @Test func boundedAssociatedResultsAndLateCanceledLoadersRetainTheNewestQuery() async throws {
        let fixture = try AuthoredReaderFixture(documents:[["Owned zero","Owned one"]]); defer {fixture.remove()}
        let data = try catalog(fixture), first = resource("one.lbxlls"), second = resource("two.lbxlls"), gate = TopicCatalogGate()
        let bounded = TopicSearchController(maximumResults:1,topicLoader:{_ in data},directoryLoader:{_ in []})
        bounded.search("crea",resources:[first],mode:.associated); try await settle(bounded)
        #expect(bounded.status == .finished(matches:1,unavailable:0,limited:false))
        bounded.search("crea",resources:[first,second],mode:.associated); try await settle(bounded)
        #expect(bounded.status == .finished(matches:1,unavailable:0,limited:true))
        let search = TopicSearchController(topicLoader:{ value in
            value.id == first.id ? await gate.load() : data
        },directoryLoader:{_ in []})
        search.search("crea",resources:[first],mode:.associated); try await gate.waitForStart()
        search.search("crea",resources:[second],mode:.associated); try await settle(search)
        await gate.finish(data); try await gate.waitForCompletion()
        #expect(search.topics.count == 1 && search.topics[0].resource == second && !search.isLoading)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func concurrentPreparationsShareOneCheckedResourceAndCancellationKeepsTheCacheUsable() async throws {
        let root = URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"]))
        let original = root.appendingPathComponent("rvr60.lbxlls"), stamp = try LegacyGraphicsService.fileStamp(original)
        let source = LibraryResource(location:original,title:"Original",byteCount:0,format:.libronixLLS,support:.metadataOnly,provenance:.fileName)
        let service = LibronixBookService()
        let prepared = try await withThrowingTaskGroup(of:LibraryResource.self) { group in
            for _ in 0..<6 { group.addTask { try await service.prepare(source) } }
            var result:[LibraryResource] = []
            for try await item in group { result.append(item) }
            return result
        }
        #expect(prepared.count == 6 && Set(prepared.map(\.location)).count == 1)
        #expect(prepared.allSatisfy { $0.indexLocation == prepared[0].indexLocation && $0.legacyIdentifier == prepared[0].legacyIdentifier })
        let canceled = Task { try await service.prepare(source) }; canceled.cancel()
        await #expect(throws:CancellationError.self) { try await canceled.value }
        #expect(try await service.prepare(source).location == prepared[0].location)
        #expect(try await service.metadata(source).title != nil)
        #expect(try LegacyGraphicsService.fileStamp(original) == stamp)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func actualTopicSelectionOpensOriginalArticlesAcrossStudyMapsAndDictionary() async throws {
        let root = URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"]))
        var receipts:[[String:Any]] = []
        for name in ["17cual.lbxlls","LBLAMAPS.lbxlls","DXMAPSET.lbxlls","STRDICTES.lbxlls"] {
            let url = root.appendingPathComponent(name), stamp = try LegacyGraphicsService.fileStamp(url)
            let outer = LibraryResource(location:url,title:name,byteCount:0,format:.libronixLLS,support:.metadataOnly,provenance:.fileName)
            let bound = try #require(try await LibronixTopicCatalogService.shared.catalog(outer))
            let index = try #require(bound.indexes.firstIndex { $0.name == "topics" })
            let topic = try #require(bound.indexes[index].topics.first { !$0.text.isEmpty && !$0.referents.isEmpty })
            let search = TopicSearchController()
            search.search(topic.text,resources:[outer],mode:.associated); try await settle(search)
            let hit = try #require(search.topics.first { Array($0.text.utf16) == Array(topic.text.utf16) && $0.indexName == "topics" },
                "Missing source key in \(name); hits=\(search.topics.count), failures=\(search.failures.map(\.message)), status=\(search.status)")
            search.selectTopic(hit.id); try await settle(search)
            #expect(search.failures.isEmpty)
            let article = try #require(search.entries.first)
            #expect(article.resource == outer && article.entry.articleID == topic.referents[0])
            let page = try await ReaderSession.read(article.resource,.init(ordinal:article.entry.sectionOrdinal))
            #expect(page.destination.ordinal == article.entry.sectionOrdinal && !page.text.isEmpty)
            #expect(try LegacyGraphicsService.fileStamp(url) == stamp)
            receipts.append(["file":name,"indexes":bound.indexes.count,"topicMatches":search.topics.count,
                "associatedArticles":search.entries.count,"openedPhysicalArticle":page.destination.ordinal,"outerResourceRetained":true,"sourceUnchanged":true])
        }
        if let path = ProcessInfo.processInfo.environment["LIBRONX_ASSOCIATED_TOPIC_RECEIPT"] {
            try JSONSerialization.data(withJSONObject:receipts,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.atomic)
        }
    }
}
private actor CatalogSequence {
    let first:LibronixTopicCatalog, second:LibronixTopicCatalog
    private var used = false
    init(_ first:LibronixTopicCatalog,_ second:LibronixTopicCatalog) {self.first=first;self.second=second}
    func next() -> LibronixTopicCatalog {defer {used=true};return used ? second : first}
}
private actor TopicCatalogGate {
    private var pending:CheckedContinuation<LibronixTopicCatalog?,Never>?
    private var completed = false
    func load() async -> LibronixTopicCatalog? {
        let result = await withCheckedContinuation { pending=$0 }
        completed = true; return result
    }
    func finish(_ value:LibronixTopicCatalog) {pending?.resume(returning:value);pending=nil}
    func waitForStart() async throws {
        for _ in 0..<400 {if pending != nil {return};try await Task.sleep(for:.milliseconds(5))}
        Issue.record("Topic catalog loader did not start")
    }
    func waitForCompletion() async throws {
        for _ in 0..<400 {if completed {return};try await Task.sleep(for:.milliseconds(5))}
        Issue.record("Topic catalog loader did not return")
    }
}
