import Foundation
import AppKit
import Testing
@testable import LibronixCore
@testable import MacRebuild

private actor BibliographyGate {
    private(set) var calls=0
    var waiters:[CheckedContinuation<Void,Never>]=[]
    func hold() async { calls += 1;await withCheckedContinuation { waiters.append($0) } }
    func release() { let next=waiters;waiters=[];for c in next { c.resume() } }
}
@MainActor struct BibliographyControllerTests {
    private func wait(_ condition:@MainActor () -> Bool) async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while !condition() && ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(2)) }
        #expect(condition())
    }
    @Test func fullLibraryIncludesAllCatalogMembersAndSelectionUsesExactSnapshotIdentity() throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let context=BibliographyContext(resources:f.resources,collections:[],collectionsError:nil)
        let all=try BibliographyController.resolve(kind:.library,collections:[],selected:[:],context:context)
        #expect(all.0 == f.resources && all.1.requestedCount == 2 && all.1.issues.isEmpty)
        let selected=[f.resources[0].id:LibraryCollectionMember(f.resources[0])]
        let one=try BibliographyController.resolve(kind:.selection,collections:[],selected:selected,context:context)
        #expect(one.0 == [f.resources[0]])
        let changed=LibraryResource(location:f.resources[0].location,title:"New edition",byteCount:0,format:.epub,support:.metadataOnly,provenance:.fileName)
        let replaced=try BibliographyController.resolve(kind:.selection,collections:[],selected:selected,context:.init(resources:[changed],collections:[],collectionsError:nil))
        #expect(replaced.0.isEmpty && replaced.1.issues.first?.reason == .changedIdentity)
        let missing=try BibliographyController.resolve(kind:.selection,collections:[],selected:selected,context:.init(resources:[],collections:[],collectionsError:nil))
        #expect(missing.1.issues.first?.reason == .missingResource)
    }
    @Test func collectionUnionKeepsMissingMembersAndIgnoresSavedTitleDriftForSameIdentity() throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let a=LibraryCollectionMember(f.resources[0]);var older=a;older.title="Old title"
        let missing=LibraryCollectionMember(.init(location:f.root.appendingPathComponent("missing.lsf"),title:"Missing",byteCount:0,format:.legacyLSF,support:.metadataOnly,provenance:.fileName))
        let one=LibraryCollection(name:"First",members:[a,missing]),two=LibraryCollection(name:"Second",members:[older,.init(f.resources[1])])
        let result=try BibliographyController.resolve(kind:.collections,collections:[one.id,two.id],selected:[:],context:.init(resources:f.resources,collections:[one,two],collectionsError:nil))
        #expect(result.0.count == 2 && result.1.requestedCount == 3 && result.1.issues.count == 1)
        let unknown=UUID(),lost=try BibliographyController.resolve(kind:.collections,collections:[unknown],selected:[:],context:.init(resources:f.resources,collections:[],collectionsError:nil))
        #expect(lost.1.issues.first?.reason == .missingCollection)
        #expect(throws:(any Error).self) { try BibliographyController.resolve(kind:.collections,collections:[one.id],selected:[:],context:.init(resources:f.resources,collections:[one],collectionsError:"Corrupt store")) }
    }
    @Test func ruleCollectionUsesCurrentMetadataAndDoesNotBecomeAllResources() throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let rule=LibraryCollectionRule(match:.all,conditions:[.init(field:.title,operation:.equals,value:f.resources[0].title)])
        let collection=LibraryCollection(name:"Rule",rule:rule)
        let result=try BibliographyController.resolve(kind:.collections,collections:[collection.id],selected:[:],context:.init(resources:f.resources,collections:[collection],collectionsError:nil))
        #expect(result.0 == [f.resources[0]])
    }
    @Test func scopeAndContextChangesRetainButDisableOldReportUntilRegenerated() async throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let c=BibliographyController();c.updateContext(.init(resources:f.resources,collections:[],collectionsError:nil));c.run()
        try await wait { !c.isLoading };let old=try #require(c.report)
        #expect(c.canExport && old.entries.count == 2)
        c.kind = .selection;c.select([f.resources[1]])
        #expect(c.configurationChanged && !c.canExport && c.report?.id == old.id)
        c.run();try await wait { !c.isLoading }
        #expect(c.canExport && c.report?.entries.map(\.id) == [f.resources[1].id])
        c.order = .title;#expect(c.canExport && c.report?.entries.count == 1)
        c.updateContext(.init(resources:[],collections:[],collectionsError:nil))
        #expect(c.configurationChanged && !c.canExport)
        c.run();try await wait { !c.isLoading }
        #expect(c.canExport && c.report?.entries.isEmpty == true && c.report?.scope.issues.first?.reason == .missingResource)
    }
    @Test func cancelledSlowRunCannotOverwriteNewScopeOrPublishAfterClose() async throws {
        let f=try AuthoredReaderFixture(documents:[["a"],["b"]]);defer { f.remove() }
        let gate=BibliographyGate(),c=BibliographyController(generate:{ resources,scope in
            let value=try BibliographyReportGenerator.generate(resources:resources,scope:scope);await gate.hold();return value
        })
        c.updateContext(.init(resources:f.resources,collections:[],collectionsError:nil));c.run()
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while await gate.calls == 0 && ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(2)) }
        #expect(await gate.calls == 1)
        c.cancel();c.kind = .selection;c.select([f.resources[0]]);await gate.release()
        try await Task.sleep(for:.milliseconds(20))
        #expect(c.report == nil && !c.isLoading && !c.canExport)
    }
    @Test func privatePasteboardAndExportsUseOneFrozenUnicodeReportAndStaleCopyDoesNothing() async throws {
        let previousStyle=ResourceCitationActions.style;ResourceCitationActions.style = .catalog
        defer { ResourceCitationActions.style=previousStyle }
        let f=try AuthoredReaderFixture(documents:[["a"]]);defer { f.remove() }
        let c=BibliographyController();c.updateContext(.init(resources:f.resources,collections:[],collectionsError:nil));c.run();try await wait { !c.isLoading }
        let report=try #require(c.report),pasteboard=NSPasteboard.withUniqueName();defer { pasteboard.releaseGlobally() }
        BibliographyExportActions.copy(c,pasteboard:pasteboard)
        #expect(pasteboard.string(forType:.string) == BibliographyReportRenderer.plainText(report,labels:BibliographyLocalization.labels))
        for kind in BibliographyExportKind.allCases {
            let data=try BibliographyExportActions.data(report,kind:kind,labels:BibliographyLocalization.labels)
            #expect(!data.isEmpty)
            let path=f.root.appendingPathComponent("report."+kind.rawValue);try BibliographyExportActions.validateDestination(path,resources:f.resources,libraryRoot:f.root);try data.write(to:path)
            #expect(try Data(contentsOf:path) == data)
        }
        pasteboard.clearContents();pasteboard.setString("Keep previous contents",forType:.string)
        c.kind = .selection;BibliographyExportActions.copy(c,pasteboard:pasteboard)
        #expect(pasteboard.string(forType:.string) == "Keep previous contents")
    }
    @Test func exportCannotReplaceBookIndexManifestOrCatalogIncludingSymlinkAliases() throws {
        let f=try AuthoredReaderFixture(documents:[["a"]]);defer { f.remove() }
        let package=f.root.appendingPathComponent("book.libron");try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        let source=package.appendingPathComponent("content.lsf"),index=package.appendingPathComponent("content.lix")
        try Data("source".utf8).write(to:source);try Data("index".utf8).write(to:index)
        let original=f.root.appendingPathComponent("original-source.html")
        let r=LibraryResource(location:source,indexLocation:index,title:"Owned",byteCount:6,format:.legacyLSF,support:.metadataOnly,provenance:.fileName,packageLocation:package,stableID:original.path)
        let link=f.root.appendingPathComponent("alias");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:package)
        for url in [original,source,index,package.appendingPathComponent("manifest.json"),f.root.appendingPathComponent("catalog.json"),link.appendingPathComponent("new.json")] {
            #expect(throws:(any Error).self, "Protected path: \(url.path)") { try BibliographyExportActions.validateDestination(url,resources:[r],libraryRoot:f.root) }
        }
        try BibliographyExportActions.validateDestination(f.root.appendingPathComponent("report.json"),resources:[r],libraryRoot:f.root)
        #expect(try Data(contentsOf:source) == Data("source".utf8) && (try? Data(contentsOf:index)) == Data("index".utf8))
    }
    @Test func copyRefreshesLiveContextBeforeTouchingThePasteboard() async throws {
        let f=try AuthoredReaderFixture(documents:[["a"]]);defer { f.remove() }
        let w=StudyWorkspace(personal:.init(url:f.root.appendingPathComponent("personal.json")),
            resourceVisibility:.init(url:f.root.appendingPathComponent("hidden.json")),recentWorkspaces:.init(url:f.root.appendingPathComponent("recent.json")),
            parallelBibleSets:.init(url:f.root.appendingPathComponent("bibles.json")),collections:.init(url:f.root.appendingPathComponent("collections.json")),
            resourcePriorities:.init(url:f.root.appendingPathComponent("priorities.json")),resourceAssociations:.init(url:f.root.appendingPathComponent("associations.json")))
        w.resources=f.resources
        let c=BibliographyController();c.updateContext(.init(resources:w.resources,collections:[],collectionsError:nil));c.run();try await wait { !c.isLoading }
        #expect(c.canExport)
        let pasteboard=NSPasteboard.withUniqueName();defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep existing",forType:.string)
        w.resources=[] // No view/onChange runs in this test.
        BibliographyExportActions.copy(c,pasteboard:pasteboard,workspace:w)
        #expect(!c.canExport && c.configurationChanged && pasteboard.string(forType:.string) == "Keep existing")
    }

}
