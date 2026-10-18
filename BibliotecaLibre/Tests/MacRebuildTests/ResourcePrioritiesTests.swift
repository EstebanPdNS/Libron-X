import Foundation
import Testing
import CSQLite
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ResourcePrioritiesTests {
    private func typed(_ resource: LibraryResource, kind: KeyLinkKind, languages: [String] = ["es"]) -> LibraryResource {
        var metadata = LibronMetadata.deriving(resource)
        metadata.resourceType = kind == .dictionary ? "Diccionario o enciclopedia" : kind.title
        metadata.languages = languages
        return .init(location: resource.location, title: resource.title, byteCount: resource.byteCount,
                     format: resource.format, support: resource.support, provenance: resource.provenance, libron: metadata)
    }
    @Test func orderedPromotionsEnabledFlagsAndCountsPersistIndependently() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"], ["two"], ["three"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("priorities.json"), store = ResourcePriorities(url: url)
        let resources = fixture.resources.map { typed($0, kind: .dictionary) }, scope = KeyLinkScope(kind: .dictionary, language: "es")
        let bytes = try resources.map { try Data(contentsOf: $0.location) }
        try store.promote(resources[2], in: scope); try store.promote(resources[1], in: scope); try store.promote(resources[2], in: scope)
        #expect(store.ordered(resources, in: scope).map(\.id) == [resources[2].id, resources[1].id, resources[0].id])
        try store.move(resources[1].id, in: scope, by: -1)
        try store.setOpenCount(2, in: scope)
        try store.setEnabled(false, resources: [resources[1]], in: scope)
        #expect(store.preference(scope).promoted.map(\.id) == [resources[1].id, resources[2].id])
        #expect(store.ordered(resources, in: scope).map(\.id) == [resources[2].id, resources[0].id])
        let reopened = ResourcePriorities(url: url)
        #expect(reopened.preferences == store.preferences && reopened.preference(scope).openCount == 2)
        try reopened.remove(resources[1].id, in: scope)
        #expect(!reopened.enabled(resources[1], in: scope))
        try reopened.setEnabled(true, resources: resources, in: scope)
        #expect(reopened.preference(scope).promoted.count == 1 && reopened.ordered(resources, in: scope).count == 3)
        #expect(try resources.map { try Data(contentsOf: $0.location) } == bytes)
    }
    @Test func datatypeLanguageAndKindsStayIndependentAndIdentityIsExact() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"], ["two"], ["three"]]); defer { fixture.remove() }
        let store = ResourcePriorities(url: fixture.root.appendingPathComponent("priorities.json"))
        let es = typed(fixture.resources[0], kind: .dictionary), en = typed(fixture.resources[1], kind: .dictionary, languages: ["en"])
        let bible = typed(fixture.resources[2], kind: .bible), scope = KeyLinkScope(kind: .dictionary, language: "es")
        try store.promote(es, in: scope)
        #expect(store.ordered([bible, en, es], in: scope) == [es])
        #expect(store.preference(.init(kind: .dictionary, language: "en")).promoted.isEmpty)
        #expect(store.preference(.init(kind: .bible)).promoted.isEmpty)
        #expect(throws: (any Error).self) { try store.promote(bible, in: scope) }
        let changed = LibraryResource(location: es.location, title: es.title, byteCount: es.byteCount,
            format: .epub, support: es.support, provenance: es.provenance, libron: es.libron)
        #expect(store.rank(changed, in: scope) == nil)
        #expect(store.preference(scope).promoted[0].resolve(in: []) == nil)
        // Generic preferences are inherited only until a datatype has its own definition.
        let generic = KeyLinkScope(kind: .dictionary)
        try store.promote(en, in: generic)
        #expect(store.rank(en, in: .init(kind: .dictionary, language: "en")) == 0)
        try store.setOpenCount(2, in: .init(kind: .dictionary, language: "en"))
        #expect(store.rank(en, in: .init(kind: .dictionary, language: "en")) == 0)
        try store.setOpenCount(3, in: generic)
        #expect(store.preference(.init(kind:.dictionary,language:"en")).openCount == 2)
        try store.reset(.init(kind:.dictionary,language:"en"))
        #expect(store.preference(.init(kind:.dictionary,language:"en")).openCount == 3)
        #expect(store.preference(scope).promoted.map(\.id) == [es.id])
    }
    @Test func embeddedDatatypesTakePrecedenceOverBibliographicLanguage() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"]]); defer { fixture.remove() }
        var metadata = LibronMetadata.deriving(typed(fixture.resources[0], kind: .dictionary, languages: ["en"]))
        let types = XMLNode(name: "data-types", content: [.element(.init(name: "data-type", attributes: ["name":"text+es", "keylink":"yes"])),
            .element(.init(name:"data-type", attributes:["name":"text+en", "keylink":"no"]))])
        metadata.originalInformation = String(data: try JSONEncoder().encode(XMLNode(name:"metadata",content:[.element(types)])), encoding:.utf8)
        let resource = LibraryResource(location: fixture.resources[0].location, title:"Bilingual", byteCount: 0,
            format:.legacyLSF, support:.metadataOnly, provenance:.fileName, libron:metadata)
        #expect(KeyLinkScope(kind:.dictionary,language:"es").supports(resource))
        #expect(!KeyLinkScope(kind:.dictionary,language:"en").supports(resource))
        #expect(!KeyLinkScope(kind:.lexicon,language:"es").supports(resource))
    }
    @Test func malformedFutureAndConcurrentStateCannotOverwriteExistingPreferences() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"]]); defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("priorities.json"), scope = KeyLinkScope(kind:.bible)
        for bytes in [Data("bad".utf8), try JSONEncoder().encode(ResourcePrioritiesSnapshot(schemaVersion:2)),
            try JSONEncoder().encode(ResourcePrioritiesSnapshot(preferences:[.init(scope:scope,openCount:0)])),
            try JSONEncoder().encode(ResourcePrioritiesSnapshot(preferences:[.init(scope:scope),.init(scope:scope)])),
            try JSONEncoder().encode(ResourcePrioritiesSnapshot(preferences:[.init(scope:.init(kind:.dictionary,language:"../es"))]))] {
            try bytes.write(to:url);let store = ResourcePriorities(url:url)
            #expect(store.loadError != nil)
            #expect(throws:(any Error).self) { try store.setOpenCount(2,in:scope) }
            #expect(try Data(contentsOf:url) == bytes)
        }
        let clean = fixture.root.appendingPathComponent("clean.json"), first = ResourcePriorities(url:clean), second = ResourcePriorities(url:clean)
        try first.setOpenCount(2,in:scope)
        do { try second.setOpenCount(3,in:scope); Issue.record("Stale priorities replaced a newer write") }
        catch PersonalStateError.concurrentChange {} catch { Issue.record("Unexpected error: \(error)") }
        try second.reload();try second.setOpenCount(3,in:scope)
        #expect(ResourcePriorities(url:clean).preference(scope).openCount == 3)
        let original = try Data(contentsOf:clean)
        #expect(throws:(any Error).self) { try second.setOpenCount(9,in:scope) }
        #expect(try Data(contentsOf:clean) == original)
    }
    @Test func sourceEditionAndExplicitReferenceTargetOverrideBiblePriorities() throws {
        let fixture = try AuthoredReaderFixture(documents: [["one"],["two"]]);defer { fixture.remove() }
        let resources = fixture.resources.map { typed($0,kind:.bible) }
        let store = ResourcePriorities(url:fixture.root.appendingPathComponent("priorities.json"))
        try store.promote(resources[1],in:.init(kind:.bible))
        let workspace = StudyWorkspace(personal:.init(url:fixture.root.appendingPathComponent("personal.json")),
            resourceVisibility:.init(url:fixture.root.appendingPathComponent("visibility.json")), resourcePriorities:store)
        workspace.resources = resources
        let source = workspace.open(resources[0],startReading:false)
        let anchor = LegacyReferenceAnchor(reference:"Ge 1:1", flags:0,dataTypeCode:0,characterOffset:0,decodedOffset:0)
        let content = LegacySectionContent.imported(text:"Authored passage",ordinal:0,anchors:[anchor],rtf:nil)
        source.page = .init(destination:.init(ordinal:0),text:content.plainText,sectionCount:1,content:content)
        func link(_ suffix:String = "") throws -> LegacyInlineLink {
            .init(range:.init(location:0,length:1),label:"verse",sourceName:"=rGe 1:1"+suffix,
                target:.bible(try #require(LegacyBibleLinkReference.parse("=rGe 1:1"+suffix))))
        }
        #expect(try workspace.resourceForInlineLink(link(),source:source.resource) == resources[1])
        workspace.referenceTargetID = source.id
        #expect(try workspace.resourceForInlineLink(link(),source:source.resource) == resources[0])
        let edition = resources[0].location.deletingPathExtension().lastPathComponent
        #expect(try workspace.resourceForInlineLink(link("("+edition+")"),source:source.resource) == resources[0])
        workspace.referenceTargetID = nil;try workspace.hideLibraryResources([resources[1].id])
        #expect(try workspace.resourceForInlineLink(link(),source:source.resource) == resources[0])
    }
}
