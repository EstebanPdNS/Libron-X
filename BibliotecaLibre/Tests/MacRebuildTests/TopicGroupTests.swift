import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct TopicGroupTests {
    private func resource(_ name: String) -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/authored/" + name), title: name, byteCount: 0,
            format: .libronixLLS, support: .metadataOnly, provenance: .fileName)
    }
    private func catalog(_ fixture: AuthoredReaderFixture, terms: [String] = ["Creación", "CREACIO\u{301}N"], stamp: Int = 1) throws -> LibronixTopicCatalog {
        let sections = try LegacyContentReader.inspectSections(lsfURL: fixture.resources[0].location)
        let entries = [1, 0].enumerated().map { row, id in
            LegacyArticleDirectoryEntry(directoryRow: row + 70, articleID: UInt32(id), level: 0,
                indexWithinLevel: UInt32(row), flags: 0, relativeTartOffset: 0,
                titleSegments: [.init(selectorCode: nil, text: "Owned \(id)")], positionLabel: nil, section: sections.sections[id])
        }
        let index = LibronixNamedTopicIndex(name: "topics", stringEncoding: 2,
            topics: terms.map { .init(text: $0, referents: [1, 0, 1]) },
            labelsByReferent: [0: terms, 1: terms])
        return try .init(indexes: [index], directory: .init(entries: entries, sections: sections, namedPositionCount: 0, warnings: []),
            sourceStamp: .init(size: UInt64(stamp), modified: Date(timeIntervalSince1970: 0), fileNumber: 1))
    }
    private func settle(_ search: TopicSearchController) async throws {
        for _ in 0..<1000 { if !search.isLoading { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Grouped topic request did not settle")
    }
    @Test func displayGroupingRetainsEveryOriginalKeyAndSeparatesAccentsAndNamedIndexes() throws {
        let first = resource("one.lbxlls"), second = resource("two.lbxlls")
        let stamp = LegacyGraphicSourceStamp(size: 1, modified: Date(timeIntervalSince1970: 0), fileNumber: 1)
        let values: [(String, String, LibraryResource)] = [
            ("Árbol", "topics", first), ("A\u{301}RBOL", "topics", second),
            ("arbol", "topics", first), ("Árbol", "city", second)
        ]
        let originals = values.enumerated().map { offset, value in
            AssociatedTopicEntry(resource: value.2, index: offset, topic: 9, indexName: value.1, text: value.0, stamp: stamp)
        }
        let grouped = AssociatedTopicGroup.grouping(originals)
        let shared = try #require(grouped.first { $0.resourceCount == 2 })
        #expect(grouped.count == 3)
        #expect(shared.members.map(\.id) == originals.prefix(2).map(\.id))
        #expect(shared.members.map { Array($0.text.utf16) } == originals.prefix(2).map { Array($0.text.utf16) })
        #expect(shared.members[0].stamp == stamp)
        #expect(Set(grouped.map(\.id)).count == 3)
        #expect(AssociatedTopicGroup.grouping([]).isEmpty)
    }
    @Test func aBoundedTopicListStillWarnsAboutMissingResourcesAfterSelectingItsArticles() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Owned zero", "Owned one"]]); defer { fixture.remove() }
        let data = try catalog(fixture, terms: ["Creación"]), first = resource("one.lbxlls"), second = resource("two.lbxlls")
        let search = TopicSearchController(maximumResults: 1, topicLoader: { _ in data }, directoryLoader: { _ in [] })
        search.search("crea", resources: [first, second], mode: .associated); try await settle(search)
        #expect(search.topicResultsLimited && search.topicGroups.count == 1)
        search.selectTopicGroup(try #require(search.topicGroups.first?.id)); try await settle(search)
        #expect(search.topicResultsLimited && search.entries.count == 2 && search.failures.isEmpty)
        for language in AppLanguage.allCases {
            #expect(AppStrings.catalog["La lista de temas es parcial; puede haber más artículos en otros recursos."]?[language.rawValue] != nil)
        }
        search.libraryDidChange()
        #expect(!search.topicResultsLimited)
    }
    @Test func groupedSelectionOpensAllOriginalResourcesAndDeduplicatesOnlyWithinEachPhysicalArticle() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Owned zero", "Owned one"]]); defer { fixture.remove() }
        let data = try catalog(fixture), first = resource("one.lbxlls"), second = resource("two.lbxlls")
        let search = TopicSearchController(topicLoader: { _ in data }, directoryLoader: { _ in [] })
        search.search("crea", resources: [first, second], mode: .associated); try await settle(search)
        #expect(search.topics.count == 4 && search.topicGroups.count == 1)
        let group = try #require(search.topicGroups.first)
        #expect(group.members.count == 4 && group.resourceCount == 2)
        #expect(search.status == .finished(matches: 1, unavailable: 0, limited: false))
        search.selectTopicGroup(group.id); try await settle(search)
        #expect(search.entries.map(\.resource.id) == [first.id, first.id, second.id, second.id])
        #expect(search.entries.map(\.entry.sectionOrdinal) == [1, 0, 1, 0])
        #expect(search.entries.map(\.entry.directoryRow) == [70, 71, 70, 71])
        #expect(search.selectedTopicGroupID == group.id && search.selectedTopicID == nil)
        search.selectTopicGroup(nil)
        #expect(search.entries.isEmpty && search.selectedTopicGroupID == nil && !search.isLoading)
    }
    @Test func changedGroupMemberIsDisclosedWithoutDiscardingAnotherOriginalResourcesArticles() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Owned zero", "Owned one"]]); defer { fixture.remove() }
        let initial = try catalog(fixture), changed = try catalog(fixture, stamp: 2)
        let first = resource("one.lbxlls"), second = resource("two.lbxlls"), sequence = TopicGroupSequence(initial: initial, changed: changed)
        let search = TopicSearchController(topicLoader: { item in
            item.id == first.id ? await sequence.next() : initial
        }, directoryLoader: { _ in [] })
        search.search("crea", resources: [first, second], mode: .associated); try await settle(search)
        search.selectTopicGroup(try #require(search.topicGroups.first?.id)); try await settle(search)
        #expect(search.entries.count == 2 && search.entries.allSatisfy { $0.resource == second })
        #expect(search.failures.map(\.resource.id) == [first.id])
        #expect(search.status == .finished(matches: 2, unavailable: 1, limited: false))
    }
    @Test func anUncooperativeGroupSelectionCannotRepopulateTheBrowserAfterItsLibraryChanges() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["Owned zero", "Owned one"]]); defer { fixture.remove() }
        let gate = TopicGroupGate(try catalog(fixture)), source = resource("one.lbxlls")
        let search = TopicSearchController(topicLoader: { _ in await gate.load() }, directoryLoader: { _ in [] })
        search.search("crea", resources: [source], mode: .associated); try await settle(search)
        await gate.blockFutureLoads()
        search.selectTopicGroup(try #require(search.topicGroups.first?.id)); try await gate.waitForStart()
        search.libraryDidChange(); await gate.finish(); try await gate.waitForCompletion()
        #expect(search.topicGroups.isEmpty && search.entries.isEmpty && search.selectedTopicGroupID == nil)
        #expect(search.status == .libraryChanged && !search.isLoading)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func aSharedOriginalTopicLoadsArticlesFromBothSuppliedStudyResources() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"]))
        let service = LibronixTopicCatalogService()
        var sources: [LibraryResource] = [], catalogs: [LibronixTopicCatalog] = [], candidates: [AssociatedTopicEntry] = []
        for name in ["17cual.lbxlls", "21CUAL.lbxlls"] {
            let source = LibraryResource(location: root.appendingPathComponent(name), title: name, byteCount: 0,
                format: .libronixLLS, support: .metadataOnly, provenance: .fileName)
            let catalog = try #require(try await service.catalog(source)); sources.append(source); catalogs.append(catalog)
            for (index, named) in catalog.indexes.enumerated() {
                for (topic, value) in named.topics.enumerated() where !value.referents.isEmpty {
                    candidates.append(.init(resource: source, index: index, topic: topic, indexName: named.name, text: value.text, stamp: catalog.sourceStamp))
                }
            }
        }
        let shared = try #require(AssociatedTopicGroup.grouping(candidates).first { $0.resourceCount == 2 })
        let search = TopicSearchController()
        search.search(shared.text, resources: sources, mode: .associated); try await settle(search)
        let group = try #require(search.topicGroups.first { $0.id == shared.id })
        #expect(group.resourceCount == 2)
        search.selectTopicGroup(group.id); try await settle(search)
        #expect(search.failures.isEmpty && Set(search.entries.map(\.resource.id)) == Set(sources.map(\.id)))
        var reads: [[String: Any]] = []
        for (source, catalog) in zip(sources, catalogs) {
            let article = try #require(search.entries.first { $0.resource == source })
            let page = try await ReaderSession.read(source, .init(ordinal: article.entry.sectionOrdinal))
            #expect(!page.text.isEmpty && page.destination.ordinal == article.entry.sectionOrdinal)
            #expect(try LegacyGraphicsService.fileStamp(source.location) == catalog.sourceStamp)
            reads.append(["file": source.fileName, "physicalArticle": page.destination.ordinal, "sourceUnchanged": true])
        }
        if let path = ProcessInfo.processInfo.environment["LIBRONX_GROUPED_TOPIC_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: ["resources": reads, "originalMembers": group.members.count, "associatedArticles": search.entries.count], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

private actor TopicGroupSequence {
    let initial: LibronixTopicCatalog, changed: LibronixTopicCatalog
    private var used = false
    init(initial: LibronixTopicCatalog, changed: LibronixTopicCatalog) { self.initial = initial; self.changed = changed }
    func next() -> LibronixTopicCatalog { defer { used = true }; return used ? changed : initial }
}
private actor TopicGroupGate {
    let value: LibronixTopicCatalog
    private var block = false, completed = false
    private var pending: CheckedContinuation<LibronixTopicCatalog, Never>?
    init(_ value: LibronixTopicCatalog) { self.value = value }
    func blockFutureLoads() { block = true }
    func load() async -> LibronixTopicCatalog {
        if !block { return value }
        let result = await withCheckedContinuation { pending = $0 }; completed = true; return result
    }
    func finish() { pending?.resume(returning: value); pending = nil }
    func waitForStart() async throws {
        for _ in 0..<400 { if pending != nil { return }; try await Task.sleep(for: .milliseconds(5)) }; Issue.record("Group loader did not start")
    }
    func waitForCompletion() async throws {
        for _ in 0..<400 { if completed { return }; try await Task.sleep(for: .milliseconds(5)) }; Issue.record("Group loader did not return")
    }
}
