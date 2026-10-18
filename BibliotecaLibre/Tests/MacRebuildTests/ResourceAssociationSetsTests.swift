import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ResourceAssociationSetsTests {
    private func typed(_ resource: LibraryResource, kind: AssociationResourceKind = .bible,
                       language: String = "es", series: String? = nil, legacy: String? = nil) -> LibraryResource {
        var m = LibronMetadata.deriving(resource)
        m.resourceType = kind == .dictionary ? "Diccionario o enciclopedia" : kind.title
        m.languages = [language]; m.collection = series
        return .init(location: resource.location, title: resource.title, byteCount: resource.byteCount,
                     format: resource.format, support: resource.support, provenance: resource.provenance,
                     legacyIdentifier: legacy, libron: m)
    }
    @Test func orderedAlternativesAndCompanionsRestoreWithoutChangingBooksOrExistingGroups() throws {
        let fixture = try AuthoredReaderFixture(documents: [["alpha"], ["beta"], ["gamma"]]); defer { fixture.remove() }
        let resources = fixture.resources.map { typed($0) }
        let before = try resources.map { try Data(contentsOf: $0.location) }
        let bibleURL = fixture.root.appendingPathComponent("bibles.json"), bibles = ParallelBibleSets(url: bibleURL)
        let bibleID = try bibles.create(); try bibles.add(resources[0], to: bibleID)
        let bibleBytes = try Data(contentsOf: bibleURL)
        let url = fixture.root.appendingPathComponent("associations.json"), store = ResourceAssociationSets(url: url)
        let id = try store.create()
        try store.configure(id, name: "  Comentarios — Ελληνικά 😀 ", relation: .companions,
                            scope: .init(language: "es"), resources: resources)
        try store.add(resources + [resources[0]], to: id)
        try store.moveMember(resources[2].id, in: id, by: -1)
        let saved = store.sets
        #expect(saved[0].name == "Comentarios — Ελληνικά 😀" && saved[0].relation == .companions)
        #expect(saved[0].members.map(\.id) == [resources[0].id,resources[2].id,resources[1].id])
        let reopened = ResourceAssociationSets(url: url)
        #expect(reopened.sets == saved)
        try reopened.removeMember(resources[2].id, from: id)
        #expect(ResourceAssociationSets(url: url).sets[0].members.map(\.id) == [resources[0].id,resources[1].id])
        try reopened.remove(id); #expect(ResourceAssociationSets(url: url).sets.isEmpty)
        #expect(try Data(contentsOf: bibleURL) == bibleBytes)
        #expect(try resources.map { try Data(contentsOf: $0.location) } == before)
    }
    @Test func compatibilityKindsLanguagesAndSeriesAreExplicit() throws {
        let fixture = try AuthoredReaderFixture(documents: [["a"],["b"],["c"]]); defer { fixture.remove() }
        for kind in [AssociationResourceKind.bible,.commentary,.dictionary,.lexicon] {
            let resource = typed(fixture.resources[0],kind:kind), wrongLanguage = typed(fixture.resources[1],kind:kind,language:"en")
            let scope = AssociationResourceScope(kind:kind,language:"es")
            #expect(scope.supports(resource) && !scope.supports(wrongLanguage))
            for other in [AssociationResourceKind.bible,.commentary,.dictionary,.lexicon] where other != kind {
                #expect(!scope.supports(typed(fixture.resources[2],kind:other)))
            }
        }
        let scope = AssociationResourceScope(kind:.series,series:"Serie Ágape")
        #expect(scope.supports(typed(fixture.resources[0],kind:.commentary,series:" serie agape ")))
        #expect(!scope.supports(typed(fixture.resources[1],kind:.commentary,series:"Different")))
        #expect(!scope.supports(typed(fixture.resources[2],kind:.commentary)))
        #expect(!AssociationResourceScope(kind:.series).supports(typed(fixture.resources[0],series:" ")))
        #expect(AssociationResourceScope(language:"es").supports(typed(fixture.resources[0],language:"spa")))
    }
    @Test func missingHiddenAndReplacedResourcesKeepMembershipButCannotResolve() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"],["two"]]); defer { fixture.remove() }
        let resources = fixture.resources.map { typed($0,legacy:"LLS:OWNED") }
        let url = fixture.root.appendingPathComponent("associations.json"), store = ResourceAssociationSets(url:url), id = try store.create()
        try store.add(resources,to:id)
        let group = try #require(ResourceAssociationSets(url:url).sets.first), member = group.members[0]
        #expect(group.resolve(member,in:[resources[1]]) == nil && group.members.count == 2)
        let replaced = typed(fixture.resources[0],legacy:"LLS:DIFFERENT")
        #expect(group.resolve(member,in:[replaced]) == nil)
        let wrongType = typed(fixture.resources[0],kind:.lexicon,legacy:"LLS:OWNED")
        #expect(group.resolve(member,in:[wrongType]) == nil)
        #expect(group.resolve(member,in:resources) == resources[0])
        let snapshot = store.sets
        #expect(throws:(any Error).self) { try store.configure(id,name:"changed",relation:.companions,
            scope:.init(kind:.commentary),resources:[resources[1]]) }
        #expect(store.sets == snapshot)
        // Renaming/relation changes preserve an unresolved member because they do not change compatibility.
        try store.configure(id,name:"Kept",relation:.companions,scope:group.scope,resources:[])
        #expect(store.sets[0].members == group.members)
    }
    @Test func incompatibleBulkAddProfileEditsNamesAndOverflowAreAtomic() throws {
        let fixture = try AuthoredReaderFixture(documents: [["a"],["b"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("associations.json"), store = ResourceAssociationSets(url:url), id = try store.create()
        let bible = typed(fixture.resources[0]); try store.add([bible],to:id)
        let bytes = try Data(contentsOf:url), snapshot = store.sets
        #expect(throws:(any Error).self) { try store.add([typed(fixture.resources[1]),typed(fixture.resources[1],kind:.lexicon)],to:id) }
        for name in [" \n ",String(repeating:"x",count:161),"bad\0name"] {
            #expect(throws:(any Error).self) { try store.configure(id,name:name,relation:.alternatives,scope:.init(),resources:[bible]) }
        }
        #expect(throws:(any Error).self) { try store.configure(id,name:"Changed",relation:.companions,scope:.init(language:"en"),resources:[bible]) }
        let overflow = (0..<257).map { i in typed(.init(location:fixture.root.appendingPathComponent("\(i).epub"),title:"\(i)",byteCount:0,format:.epub,support:.metadataOnly,provenance:.fileName)) }
        #expect(throws:(any Error).self) { try store.add(overflow,to:id) }
        #expect(store.sets == snapshot)
        #expect(try Data(contentsOf:url) == bytes)
    }
    @Test func malformedFutureDuplicateUnsafeAndInvalidScopeStateCannotBeOverwritten() throws {
        let fixture = try AuthoredReaderFixture(documents:[["a"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("associations.json"), member = LibraryCollectionMember(typed(fixture.resources[0]))
        var unsafe = member; unsafe.resourceID = "/tmp/../book"
        let set = ResourceAssociationSet(name:"a",members:[member])
        let invalid = [ResourceAssociationSetsSnapshot(schemaVersion:2),.init(sets:[set,set]),
                       .init(sets:[.init(name:"a",members:[member,member])]),.init(sets:[.init(name:"a",members:[unsafe])]),
                       .init(sets:[.init(name:"a",scope:.init(kind:.series))]),
                       .init(sets:[.init(name:"a",scope:.init(language:"spa"))])]
        for bytes in [Data("broken json".utf8)] + (try invalid.map { try JSONEncoder().encode($0) }) {
            try bytes.write(to:url)
            let store = ResourceAssociationSets(url:url)
            #expect(store.loadError != nil)
            #expect(throws:(any Error).self) { try store.create() }
            #expect(try Data(contentsOf:url) == bytes)
        }
    }
    @Test func concurrentWriterMustReloadAndRecoveryKeepsValidState() throws {
        let fixture = try AuthoredReaderFixture(documents:[["a"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("associations.json"), first = ResourceAssociationSets(url:url), second = ResourceAssociationSets(url:url)
        let id = try first.create(), bytes = try Data(contentsOf:url)
        do { _ = try second.create(); Issue.record("Concurrent writer overwrote associations") }
        catch PersonalStateError.concurrentChange { }
        #expect(second.sets.isEmpty)
        #expect(try Data(contentsOf:url) == bytes)
        try second.reload(); let next = try second.create()
        #expect(next != id && second.sets[0].name != second.sets[1].name)
        let saved = second.sets, valid = try Data(contentsOf:url)
        try Data("broken".utf8).write(to:url)
        #expect(throws:(any Error).self) { try second.reload() }
        #expect(second.sets == saved)
        #expect(throws:(any Error).self) { try second.remove(next) }
        try valid.write(to:url); try second.reload(); try second.remove(next)
        #expect(second.sets.map(\.id) == [id])
    }
    @Test func persistedCommentaryLexiconAndSeriesScopesRoundTripWithValidatedProfileChanges() throws {
        let fixture = try AuthoredReaderFixture(documents: [["a"],["b"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("associations.json"), store = ResourceAssociationSets(url:url)
        for kind in [AssociationResourceKind.commentary,.dictionary,.lexicon,.series] {
            let id = try store.create()
            let scope = AssociationResourceScope(kind:kind,language:"es",series:kind == .series ? "Serie Uno" : "")
            let resource = typed(fixture.resources[0],kind:kind,series:kind == .series ? "Serie Uno" : nil)
            try store.configure(id,name:kind.rawValue,relation:.companions,scope:scope,resources:[resource])
            try store.add([resource],to:id)
            let restored = try #require(ResourceAssociationSets(url:url).sets.first { $0.id == id })
            #expect(restored.scope == scope && restored.relation == .companions)
            #expect(restored.resolve(restored.members[0],in:[resource]) == resource)
        }
        let id = try store.create(), bible = typed(fixture.resources[1])
        try store.add([bible],to:id)
        // Narrowing to a compatible language is valid without removing members.
        try store.configure(id,name:"Narrowed",relation:.alternatives,scope:.init(language:"es"),resources:[bible])
        #expect(store.sets.last?.members.count == 1 && store.sets.last?.scope.language == "es")
        for invalid in ["-","es--es","es en","es_XX","a",String(repeating:"a",count:33)] {
            #expect(throws:(any Error).self) { try AssociationResourceScope(language:invalid).validate() }
        }
    }
    @Test func hiddenResourcesRestoreAgainstExactIdentityWithoutRewritingDefinitions() throws {
        let fixture = try AuthoredReaderFixture(documents:[["a"]]); defer { fixture.remove() }
        let resource = typed(fixture.resources[0]), url = fixture.root.appendingPathComponent("associations.json")
        let store = ResourceAssociationSets(url:url), id = try store.create(); try store.add([resource],to:id)
        let workspace = StudyWorkspace(personal:.init(url:fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility:.init(url:fixture.root.appendingPathComponent("hidden.json")),
            recentWorkspaces:.init(url:fixture.root.appendingPathComponent("recent.json")),
            parallelBibleSets:.init(url:fixture.root.appendingPathComponent("bibles.json")),
            collections:.init(url:fixture.root.appendingPathComponent("collections.json")),
            resourcePriorities:.init(url:fixture.root.appendingPathComponent("priorities.json")),resourceAssociations:store)
        workspace.resources = [resource]
        let bytes = try Data(contentsOf:url), set = try #require(store.sets.first), member = set.members[0]
        try workspace.hideLibraryResources([resource.id])
        #expect(set.resolve(member,in:workspace.availableResources) == nil && store.sets[0].members.count == 1)
        try workspace.restoreLibraryResources([resource.id])
        #expect(set.resolve(member,in:workspace.availableResources) == resource)
        #expect(try Data(contentsOf:url) == bytes)
    }

}
