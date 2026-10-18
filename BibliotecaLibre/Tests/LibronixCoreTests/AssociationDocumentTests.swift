import Foundation
import Testing
@testable import LibronixCore

struct AssociationDocumentTests {
    @Test func selectedOriginalPreservesEncodingOrderAttributesAndBytesWithoutScanningSiblings() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("cafe.lbxras")
        let xml="<?xml version=\"1.0\" encoding=\"iso-8859-1\"?><lbx-resource-association name=\"Cafe\" category=\"ResourceAssociations\"><header><title xml:lang=\"es\">Café original</title></header><association guid=\"GROUP\" priority=\"007\" type=\"parallel\" custom=\"kept\"><resource guid=\"LLS:B\"/><resource guid=\"LLS:A\"/><resource guid=\"LLS:B\"/></association></lbx-resource-association>"
        let bytes=try #require(xml.data(using:.isoLatin1));try bytes.write(to:source)
        try Data("invalid unrelated XML".utf8).write(to:root.appendingPathComponent("unrelated.lbxras"))
        let doc=try MetadataImporter.readAssociation(at:source)
        #expect(doc.data == bytes && doc.source == source && doc.definition.title == "Café original")
        #expect(doc.definition.resourceIDs == ["LLS:B","LLS:A","LLS:B"])
        #expect(doc.definition.groups[0].priority == 7 && doc.definition.groups[0].priorityText == "007")
        #expect(doc.definition.groups[0].attributes["custom"] == "kept" && doc.definition.groups[0].type == "parallel")
        #expect(try Data(contentsOf:source) == bytes)
    }
    @Test func malformedGuidUnknownRootAndExternalDeclarationsCannotBecomeUsableGroups() throws {
        let url=URL(fileURLWithPath:"/owned/example.lbxras")
        for xml in ["<lbx-resource-association><association><resource/></association></lbx-resource-association>",
                    "<lbx-resource-association><association><resource guid=\"\"/></association></lbx-resource-association>",
                    "<not-an-association/>","<!DOCTYPE a SYSTEM 'file:///never-read'><lbx-resource-association/>",
                    "<!DOCTYPE a [<!ENTITY x SYSTEM 'https://example.invalid/never-read'>]><lbx-resource-association>&x;</lbx-resource-association>"] {
            #expect(throws:(any Error).self) { try MetadataImporter.associationDocument(data:Data(xml.utf8),source:url) }
        }
    }
    @Test func selectedDirectoriesLinksAndNonFileURLsAreRefused() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("source.lbxras"),link=root.appendingPathComponent("link.lbxras")
        try Data("<lbx-resource-association/>".utf8).write(to:source)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        for url in [root,link,try #require(URL(string:"https://example.invalid/never-read"))] {
            #expect(throws:(any Error).self) { try MetadataImporter.readAssociation(at:url) }
        }
    }
    @Test func obsoleteDefinitionsRemainExplicitInsteadOfInventingMembership() throws {
        let doc=try MetadataImporter.associationDocument(data:Data("<lbx-resource-association name=\"Old\"><!-- made obsolete --></lbx-resource-association>".utf8),source:URL(fileURLWithPath:"/owned/old.lbxras"))
        #expect(doc.definition.groups.isEmpty && doc.definition.definitionState == .obsoletePlaceholder)
    }
}
