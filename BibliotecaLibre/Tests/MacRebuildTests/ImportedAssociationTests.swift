import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ImportedAssociationTests {
    private func document(_ root: URL, resources: [String] = ["LLS:A","LLS:MISSING","LLS:B"], extraGroup: Bool = false) throws -> ResourceAssociationDocument {
        let url=root.appendingPathComponent("original.lbxras")
        let refs=resources.map { "<resource guid=\"\($0)\"/>" }.joined()
        let second=extraGroup ? "<association guid=\"SECOND\" priority=\"90\"><resource guid=\"LLS:C\"/></association>" : ""
        let xml="<lbx-resource-association category=\"ResourceAssociations\" name=\"Owned\"><header><title xml:lang=\"es\">Serie original 😀</title></header><association guid=\"GROUP\" type=\"parallel\" priority=\"050\">\(refs)</association>\(second)</lbx-resource-association>"
        try Data(xml.utf8).write(to:url);return try MetadataImporter.readAssociation(at:url)
    }
    private func resource(_ r: LibraryResource, guid: String, title: String? = nil) -> LibraryResource {
        var m=LibronMetadata.deriving(r);m.resourceType="Comentario bíblico";m.collection=nil
        return .init(location:r.location,title:title ?? r.title,byteCount:r.byteCount,format:r.format,support:r.support,provenance:r.provenance,legacyIdentifier:guid,libron:m)
    }
    @Test func originalOrderMissingMembersRawProvenanceAndEditsRestoreWithoutOriginalFile() throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let rs=zip(f.resources,["LLS:A","LLS:B"]).map { resource($0.0,guid:$0.1) },doc=try document(f.root)
        let url=f.root.appendingPathComponent("sets.json"),store=ResourceAssociationSets(url:url)
        let id=try #require(store.importOriginal(doc,relation:.companions,resources:rs).first)
        let g=try #require(store.sets.first),catalog=ResourceAssociationCatalog(resources:rs)
        #expect(g.members.map(\.legacyIdentifier) == ["LLS:A","LLS:MISSING","LLS:B"])
        #expect(g.resolve(g.members[0],using:catalog) == rs[0] && g.resolve(g.members[1],using:catalog) == nil)
        #expect(g.resolve(g.members[2],using:catalog) == rs[1] && g.relation == .companions)
        #expect(g.original?.sourceBytes == doc.data && g.original?.group.priorityText == "050")
        try store.moveMember(g.members[2].id,in:id,by:-1)
        try store.configure(id,name:"Edited copy",relation:.alternatives,scope:g.scope,resources:rs)
        let edited=store.sets,bytes=try Data(contentsOf:url)
        #expect(try store.importOriginal(doc,relation:.companions,resources:rs) == [id])
        #expect(store.sets == edited && (try? Data(contentsOf:url)) == bytes)
        try FileManager.default.removeItem(at:doc.source)
        #expect(ResourceAssociationSets(url:url).sets == edited)
        #expect(store.sets[0].members.map(\.legacyIdentifier) == ["LLS:A","LLS:B","LLS:MISSING"])
    }
    @Test func aliasesAmbiguityAndExplicitEditionBindingRemainExactAcrossRestart() throws {
        let f=try AuthoredReaderFixture(documents:[["one"],["two"]]);defer { f.remove() }
        var a=resource(f.resources[0],guid:"LLS:PRIMARY"),b=resource(f.resources[1],guid:"lls:a")
        var metadata=try #require(a.libron)
        metadata.originalInformation=String(data:try JSONEncoder().encode(XMLNode(name:"metadata",content:[.element(.init(name:"alternate-id",attributes:["guid":"LLS:A"]))])),encoding:.utf8)
        a = .init(location:a.location,title:a.title,byteCount:a.byteCount,format:a.format,support:a.support,provenance:a.provenance,legacyIdentifier:a.legacyIdentifier,libron:metadata)
        let url=f.root.appendingPathComponent("sets.json"),store=ResourceAssociationSets(url:url),doc=try document(f.root,resources:["LLS:A"])
        let id=try #require(store.importOriginal(doc,relation:.alternatives,resources:[a,b]).first),g=try #require(store.sets.first),member=g.members[0]
        #expect(g.isAmbiguous(member,using:.init(resources:[a,b])) && g.resolve(member,in:[a,b]) == nil)
        try store.bind(member.id,in:id,to:a,resources:[a,b])
        let restored=try #require(ResourceAssociationSets(url:url).sets.first)
        #expect(restored.resolve(member,in:[a,b]) == a)
        #expect(restored.resolve(member,in:[b]) == nil) // Never silently select another edition when the chosen one disappears.
        try store.bind(member.id,in:id,to:nil,resources:[a,b])
        #expect(store.sets[0].resolve(member,in:[a,b]) == nil)
        b=resource(f.resources[1],guid:"LLS:WRONG")
        #expect(throws:(any Error).self) { try store.bind(member.id,in:id,to:b,resources:[a,b]) }
        #expect(store.sets[0].resolve(member,in:[a]) == a)
    }
    @Test func declaredSeriesCanNavigateWithoutInferredCollectionMetadataButTypedScopeStillRestricts() async throws {
        let f=try AuthoredReaderFixture(documents:[["Actual article"]]);defer { f.remove() }
        let r=resource(f.resources[0],guid:"LLS:A"),doc=try document(f.root,resources:["LLS:A"])
        let store=ResourceAssociationSets(url:f.root.appendingPathComponent("sets.json"))
        _=try store.importOriginal(doc,relation:.alternatives,resources:[r]);let g=try #require(store.sets.first)
        #expect(!g.scope.supports(r) && g.supports(r))
        let found=try #require(try await AssociationNavigationController.resolve(r,scope:g,mode:.start,query:""))
        #expect(found.page.text.contains("Actual article"))
        let originalID=g.members[0].id
        try store.removeMember(originalID,from:g.id);try store.add([r],to:g.id)
        #expect(store.sets[0].members[0].id == r.id && store.sets[0].resolve(store.sets[0].members[0],in:[r]) == r)
        let restricted=ResourceAssociationSets(url:f.root.appendingPathComponent("restricted.json"))
        _=try restricted.importOriginal(doc,relation:.companions,kind:.lexicon,resources:[r])
        let typed=try #require(restricted.sets.first)
        #expect(typed.members.count == 1 && typed.resolve(typed.members[0],in:[r]) == nil)
    }
    @Test func removingReorderingAndAddingOwnedMembersPreservesOriginalEvidenceAndBindingBounds() throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"],["c"]]);defer { f.remove() }
        let rs=zip(f.resources,["LLS:A","LLS:B","LLS:C"]).map { resource($0.0,guid:$0.1) },doc=try document(f.root,resources:["LLS:A","LLS:B"])
        let url=f.root.appendingPathComponent("sets.json"),store=ResourceAssociationSets(url:url)
        let id=try #require(store.importOriginal(doc,relation:.companions,kind:.commentary,resources:rs).first)
        let original=try #require(store.sets.first?.original),member=store.sets[0].members[0]
        try store.bind(member.id,in:id,to:rs[0],resources:rs)
        try store.add([rs[0],rs[2]],to:id)
        #expect(store.sets[0].members.count == 3)
        try store.removeMember(member.id,from:id)
        #expect(store.sets[0].originalBindings?[member.id] == nil && store.sets[0].original == original)
        #expect(ResourceAssociationSets(url:url).sets == store.sets)
    }
    @Test func malformedProvenanceHashCachedGroupAndBindingAreBlockedWithoutOverwritingState() throws {
        let f=try AuthoredReaderFixture(documents:[["a"]]);defer { f.remove() }
        let r=resource(f.resources[0],guid:"LLS:A"),url=f.root.appendingPathComponent("sets.json"),store=ResourceAssociationSets(url:url)
        _=try store.importOriginal(try document(f.root,resources:["LLS:A"]),relation:.alternatives,resources:[r])
        let good=try Data(contentsOf:url),base=try #require(JSONSerialization.jsonObject(with:good) as? [String:Any])
        for mode in 0..<4 {
            var value=base,sets=try #require(value["sets"] as? [[String:Any]]),first=sets[0],original=try #require(first["original"] as? [String:Any])
            if mode == 0 { original["sha256"]=String(repeating:"0",count:64) }
            if mode == 1 { original["groupIndex"]=99 }
            if mode == 2 { original["definitionID"]="forged" }
            if mode == 3 { value["schemaVersion"]=1 }
            first["original"]=original;sets[0]=first;value["sets"]=sets
            let bytes=try JSONSerialization.data(withJSONObject:value);try bytes.write(to:url)
            let rejected=ResourceAssociationSets(url:url)
            #expect(rejected.loadError != nil)
            #expect(throws:(any Error).self) { try rejected.create() }
            #expect(try Data(contentsOf:url) == bytes)
        }
    }
    @Test func allGroupsImportAtomicallyAndChangedDocumentCreatesANewVersionWithoutLosingEdits() throws {
        let f=try AuthoredReaderFixture(documents:[["a"]]);defer { f.remove() }
        let store=ResourceAssociationSets(url:f.root.appendingPathComponent("sets.json")),doc=try document(f.root,extraGroup:true)
        let ids=try store.importOriginal(doc,relation:.alternatives,resources:[])
        #expect(ids.count == 2 && store.sets.map { $0.original?.groupIndex } == [0,1])
        let first=store.sets
        let changed=try document(f.root,resources:["LLS:NEW"])
        let next=try store.importOriginal(changed,relation:.companions,resources:[])
        #expect(next.count == 1 && !ids.contains(next[0]) && Array(store.sets.prefix(2)) == first)
        #expect(store.sets[2].name != first[0].name)
        let obsolete=try MetadataImporter.associationDocument(data:Data("<lbx-resource-association><!-- obsolete --></lbx-resource-association>".utf8),source:f.root.appendingPathComponent("old.lbxras"))
        #expect(throws:(any Error).self) { try store.importOriginal(obsolete,relation:.alternatives,resources:[]) }
        #expect(store.sets.count == 3)
    }
    @Test func importedSeriesControllerNavigatesVirtualMembersAndKeepsExistingOwnedGroups() async throws {
        let f=try AuthoredReaderFixture(documents:[["Source article"],["Target article"]]);defer { f.remove() }
        let rs=zip(f.resources,["LLS:A","LLS:B"]).map { resource($0.0,guid:$0.1) },url=f.root.appendingPathComponent("sets.json")
        let store=ResourceAssociationSets(url:url),ownedID=try store.create()
        let original=try document(f.root,resources:["LLS:A","LLS:B"])
        let importedID=try #require(store.importOriginal(original,relation:.alternatives,resources:rs).first)
        let imported=try #require(store.sets.first { $0.id == importedID })
        let w=StudyWorkspace(personal:.init(url:f.root.appendingPathComponent("personal.json")),
            resourceVisibility:.init(url:f.root.appendingPathComponent("hidden.json")),recentWorkspaces:.init(url:f.root.appendingPathComponent("recent.json")),
            parallelBibleSets:.init(url:f.root.appendingPathComponent("bibles.json")),collections:.init(url:f.root.appendingPathComponent("collections.json")),
            resourcePriorities:.init(url:f.root.appendingPathComponent("priorities.json")),resourceAssociations:store)
        w.resources=rs;let source=w.open(rs[0])
        var deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while source.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(2)) }
        w.beginAssociatedResources(groupID:importedID,source:source)
        w.associationNavigation.open(imported.members[1],workspace:w)
        deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while w.associationNavigation.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(2)) }
        #expect(!w.associationNavigation.isLoading && w.associationNavigation.error == nil)
        #expect(w.readers.count == 1 && source.resource == rs[1] && source.page?.text.contains("Target article") == true)
        #expect(store.sets.first?.id == ownedID && store.sets.count == 2)
        #expect(ResourceAssociationSets(url:url).sets == store.sets)
    }
    @Test func staleImportCannotOverwriteAndRemovingOriginalsReturnsToLegacySchema() throws {
        let f=try AuthoredReaderFixture(documents:[["a"]]);defer { f.remove() }
        let url=f.root.appendingPathComponent("sets.json"),first=ResourceAssociationSets(url:url),stale=ResourceAssociationSets(url:url)
        let owned=try first.create(),doc=try document(f.root)
        let before=try Data(contentsOf:url)
        do { _=try stale.importOriginal(doc,relation:.companions,resources:[]);Issue.record("Stale import overwrote state") }
        catch PersonalStateError.concurrentChange { }
        #expect(try Data(contentsOf:url) == before)
        let imported=try first.importOriginal(doc,relation:.alternatives,resources:[])
        for id in imported { try first.remove(id) }
        let value=try JSONDecoder().decode(ResourceAssociationSetsSnapshot.self,from:Data(contentsOf:url))
        #expect(value.schemaVersion == 1 && value.sets.map(\.id) == [owned])
    }

}
