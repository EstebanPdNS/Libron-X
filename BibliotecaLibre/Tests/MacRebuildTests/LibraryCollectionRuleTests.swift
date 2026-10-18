import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct LibraryCollectionRuleTests {
    private func resource(_ id: Int, metadata: LibronMetadata? = nil, format: ResourceFormat = .legacyLSF) -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/tmp/rule-owned-\(id).LSF"), title: "Title \(id)", byteCount: 0,
              format: format, support: .metadataOnly, provenance: .fileName, libron: metadata)
    }
    private func rule(_ field: LibraryCollectionRule.Field, _ operation: LibraryCollectionRule.Operation, _ value: String = "") -> LibraryCollectionRule {
        .init(conditions: [.init(field: field, operation: operation, value: value)])
    }
    @Test func allMetadataFieldsAreQueryableWithoutReadingTheResource() throws {
        var m = LibronMetadata(title: "Árbol de vida", origin: "Logos")
        m.authors = ["Álvarez", "García"]; m.languages = ["es-MX"]; m.resourceType = "Comentario bíblico"
        m.category = "Teología"; m.tags = ["Cristología", "Estudio"]; m.publisher = "Editorial Uno"; m.year = "1998"
        m.collection = "Serie A"; m.subtitle = "Subtítulo"; m.contributors = ["Editor Uno"]; m.edition = "Revisada"
        m.originalYear = "1898"; m.biblicalCoverage = "Romanos"; m.subcategories = ["Doctrina"]; m.abbreviation = "AV"
        let r = resource(1, metadata: m)
        let values: [LibraryCollectionRule.Field:String] = [.title:"arbol", .author:"garcia", .language:"es", .format:"legacyLSF", .resourceType:"comentario", .category:"teologia", .tag:"cristologia", .publisher:"uno", .year:"1998", .series:"serie a", .origin:"logos", .fileName:"rule-owned-1", .subtitle:"subtitulo", .contributor:"editor", .edition:"revisada", .originalYear:"1898", .coverage:"romanos", .subcategory:"doctrina", .abbreviation:"av"]
        #expect(values.count == LibraryCollectionRule.Field.allCases.count)
        for (field,value) in values { #expect(rule(field,.contains,value).matches(r)); #expect(!rule(field,.notContains,value).matches(r)) }
        #expect(rule(.author,.equals,"GARCÍA").matches(r))
        #expect(!rule(.author,.notEquals,"Álvarez").matches(r))
        #expect(rule(.title,.startsWith,"arbol").matches(r))
        #expect(!rule(.title,.equals,"arbol").matches(r))
        #expect(rule(.language,.equals,"es-MX").matches(r))
        #expect(rule(.format,.equals,"Logos LSF").matches(r))
        #expect(rule(.author,.notContains,"unknown").matches(r))
    }
    @Test func missingMetadataNeedsAnExplicitMissingConditionAndBooleanModesDiscriminate() throws {
        let r = resource(1)
        #expect(rule(.publisher,.missing).matches(r))
        #expect(!rule(.publisher,.exists).matches(r))
        #expect(!rule(.publisher,.notEquals,"known").matches(r))
        #expect(!rule(.publisher,.notContains,"known").matches(r))
        var combined = LibraryCollectionRule(conditions: [.init(field: .title, value: "Title"), .init(field: .format, operation: .equals, value: "EPUB")])
        #expect(!combined.matches(r)); combined.match = .any; #expect(combined.matches(r))
        combined.conditions[0].value = "Other"; #expect(!combined.matches(r))
    }
    @Test func manualVersionOneLoadsUnchangedAndRuleStateRoundTripsWithoutFlatteningMembers() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("collections.json")
        let manual = LibraryCollection(name: "Manual", members: [.init(fixture.resources[0])])
        let old = try JSONEncoder().encode(LibraryCollectionsSnapshot(sets: [manual])); try old.write(to: url)
        let store = LibraryCollections(url: url); #expect(store.loadError == nil && store.sets == [manual])
        #expect(try Data(contentsOf: url) == old)
        let id = try store.create(rule: rule(.title,.contains,"Title"))
        let snapshot = try JSONDecoder().decode(LibraryCollectionsSnapshot.self, from: Data(contentsOf: url))
        #expect(snapshot.schemaVersion == 2 && snapshot.sets[0] == manual && snapshot.sets[1].members.isEmpty)
        #expect(LibraryCollections(url: url).sets == store.sets)
        try store.saveRule(rule(.format,.equals,"epub"), for: id)
        try store.rename(id, to: "Automatic")
        #expect(LibraryCollections(url: url).sets[1].name == "Automatic")
        try store.remove(id)
        #expect(try JSONDecoder().decode(LibraryCollectionsSnapshot.self, from: Data(contentsOf: url)).schemaVersion == 1)
        #expect(store.sets == [manual])
    }
    @Test func rulesReevaluateOnImportsMetadataChangesVisibilityAndScopeUnion() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"],["two"]]); defer { fixture.remove() }
        let store = LibraryCollections(url: fixture.root.appendingPathComponent("collections.json"))
        let id = try store.create(rule: rule(.format,.equals,"legacyLSF")), manual = try store.create()
        try store.add(fixture.resources[0], to: manual)
        let workspace = StudyWorkspace(personal: .init(url: fixture.root.appendingPathComponent("personal.json")), resourceVisibility: .init(url: fixture.root.appendingPathComponent("visibility.json")), parallelBibleSets: .init(url: fixture.root.appendingPathComponent("bibles.json")), collections: store)
        let a = resource(1), b = resource(2), c = resource(3,format:.epub)
        workspace.resources = [a,c]; workspace.libraryGroup = "collection:" + id.uuidString
        #expect(workspace.filteredResources.map(\.id) == [a.id])
        workspace.resources = [a,b,c]
        #expect(Set(workspace.filteredResources.map(\.id)) == [a.id,b.id])
        try workspace.resourceVisibility.hide([b]); #expect(workspace.filteredResources.map(\.id) == [a.id])
        let selection = WorkspaceSearchScopeSelection(); selection.kind = .collections; selection.collectionIDs = [id,manual]
        let scope = try WorkspaceSearchScopeResolver.resolve(selection, context: workspace.searchScopeContext())
        #expect(scope.resources.map(\.id) == [a.id] && !scope.complete)
        #expect(scope.issues.contains { $0.id == b.id && $0.reason == .hidden })
        workspace.resources = [c]; #expect(workspace.filteredResources.isEmpty)
        #expect(store.sets.first { $0.id == id }?.members.isEmpty == true)
        #expect(store.sets.first { $0.id == manual }?.members.map(\.id) == fixture.resources.prefix(1).map(\.id))
        var m = LibronMetadata(title: "Changed", origin: "Test");m.publisher = "Owned"
        try store.saveRule(rule(.publisher,.equals,"Owned"), for: id)
        workspace.resources = [resource(4),resource(5,metadata:m)]
        #expect(workspace.filteredResources.map(\.id) == [resource(5).id])
    }
    @Test func invalidRulesManualConversionAndMemberEditsAreAtomic() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("collections.json"), store = LibraryCollections(url: url)
        let manual = try store.create(), automatic = try store.create(rule: rule(.title,.exists))
        let bytes = try Data(contentsOf: url), state = store.sets
        let condition = LibraryCollectionRule.Condition(value:"a")
        let invalid: [LibraryCollectionRule] = [.init(conditions:[]), .init(conditions:Array(repeating:condition,count:33)), .init(conditions:[condition,condition]),rule(.title,.contains,"  "),rule(.title,.equals,"bad\0value"),rule(.title,.contains,String(repeating:"a",count:513))]
        for rule in invalid {
            #expect(throws:(any Error).self) { try store.create(rule:rule) }
            #expect(throws:(any Error).self) { try store.saveRule(rule, for:automatic) }
        }
        #expect(throws:(any Error).self) { try store.saveRule(rule(.title,.exists), for:manual) }
        #expect(throws:(any Error).self) { try store.add(fixture.resources[0],to:automatic) }
        #expect(throws:(any Error).self) { try store.removeMember(fixture.resources[0].id,from:automatic) }
        #expect(throws:(any Error).self) { try store.moveMember(fixture.resources[0].id,in:automatic,by:1) }
        #expect(store.sets == state)
        #expect(try Data(contentsOf:url) == bytes)
    }
    @Test func malformedRuleStateCannotBeOverwritten() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("collections.json")
        let invalid = LibraryCollection(name:"Invalid",rule:rule(.title,.equals,""))
        for snapshot in [LibraryCollectionsSnapshot(sets:[invalid]),.init(schemaVersion:2,sets:[invalid]),.init(schemaVersion:3,sets:[]),.init(schemaVersion:2,sets:[.init(name:"Both",members:[.init(fixture.resources[0])],rule:rule(.title,.exists))])] {
            let bytes = try JSONEncoder().encode(snapshot);try bytes.write(to:url)
            let store = LibraryCollections(url:url);#expect(store.loadError != nil)
            #expect(throws:(any Error).self) { try store.create(rule:rule(.title,.exists)) }
            #expect(try Data(contentsOf:url) == bytes)
        }
    }
    @Test func staleRuleWritersMustReloadBeforeCommitting() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("collections.json"), first = LibraryCollections(url:url)
        let id = try first.create(rule:rule(.title,.exists)), second = LibraryCollections(url:url)
        try first.saveRule(rule(.format,.equals,"epub"),for:id)
        do { try second.saveRule(rule(.title,.contains,"other"),for:id); Issue.record("Stale rule replaced current state") }
        catch PersonalStateError.concurrentChange {}
        catch { Issue.record("Unexpected error: \(error)") }
        try second.reload();#expect(second.sets == first.sets)
    }
    @Test func importedMatchesReachBothSearchControllersAndAreFrozenPerRequest() async throws {
        let fixture = try AuthoredReaderFixture(documents: [["needle John3:16"],["needle John3:16"]]); defer { fixture.remove() }
        let store = LibraryCollections(url:fixture.root.appendingPathComponent("collections.json"))
        let id = try store.create(rule:rule(.format,.equals,"legacyLSF"))
        let workspace = StudyWorkspace(personal:.init(url:fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility:.init(url:fixture.root.appendingPathComponent("visibility.json")),
            parallelBibleSets:.init(url:fixture.root.appendingPathComponent("bibles.json")),collections:store)
        workspace.resources = Array(fixture.resources.prefix(1))
        let search = workspace.search;search.scope.kind = .collections;search.scope.collectionIDs = [id];search.query = "needle"
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for:.milliseconds(5)) }
            Issue.record("Rule search did not settle")
        }
        search.run(workspace.resources,scopeContext:workspace.searchScopeContext())
        workspace.resources = fixture.resources
        try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.count == 1 && search.scopeSnapshot?.resources.count == 1)
        search.run(workspace.resources,scopeContext:workspace.searchScopeContext());try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.count == 2)
        let refs = workspace.referenceSearch;refs.scope.kind = .collections;refs.scope.collectionIDs = [id]
        refs.query = "John3:16";refs.includeDocuments = false
        refs.run(resources:workspace.resources,documents:[],scopeContext:workspace.searchScopeContext());try await settle { !refs.isSearching }
        #expect(refs.coverageComplete && refs.report?.results.count == 2)
        try store.saveRule(rule(.title,.equals,"Synthetic 2"),for:id)
        #expect(search.scopeSnapshot?.resources.count == 2)
        search.run(workspace.resources,scopeContext:workspace.searchScopeContext());try await settle { !search.isSearching }
        #expect(search.coverageComplete && search.report?.results.map(\.resourceID) == [fixture.resources[1].id])
    }

}
