import Foundation
import Testing
@testable import LibronixCore

@Test func metadataPreservesMixedContentAndWhitespace() throws {
    let xml = #"<root xml:lang="es"><pattern xml:space="preserve">^v </pattern><text>A<b>B</b><![CDATA[ C ]]></text><!-- obsolete --></root>"#
    let root = try MetadataXMLReader.parse(Data(xml.utf8))
    #expect(root.attributes["xml:lang"] == "es")
    #expect(root.child(named: "pattern")?.text == "^v ")
    #expect(root.child(named: "text")?.text == "AB C ")
    #expect(root.comments == [" obsolete "])
    let copy = try JSONDecoder().decode(XMLNode.self, from: JSONEncoder().encode(root))
    #expect(copy == root)
}

@Test func metadataSupportsDeclaredLegacyEncoding() throws {
    let xml = #"<?xml version="1.0" encoding="iso-8859-1"?><title>Párrafos sencillos</title>"#
    let data = try #require(xml.data(using: .isoLatin1))
    #expect(try MetadataXMLReader.parse(data).text == "Párrafos sencillos")
}

@Test func metadataRejectsOpaqueContainersAndDeclarations() throws {
    #expect(throws: MetadataReadError.self) { try MetadataXMLReader.parse(Data([0x4c, 0x54, 0x45, 0x53])) }
    let dtd = #"<!DOCTYPE root [<!ENTITY private SYSTEM "file:///tmp/no-external-read">]><root>&private;</root>"#
    for encoding in [String.Encoding.utf8, .utf16LittleEndian] {
        let data = try #require(dtd.data(using: encoding))
        do {
            _ = try MetadataXMLReader.parse(data)
            Issue.record("Se aceptó un documento con DTD")
        } catch MetadataReadError.prohibitedDeclaration {
            // Expected before entity resolution or external I/O.
        }
    }
    #expect(throws: MetadataReadError.self) { try MetadataXMLReader.parse(Data("<root><x></root>".utf8)) }
}

@Test func metadataEnforcesSizeAndDepthLimits() throws {
    #expect(throws: MetadataReadError.self) {
        try MetadataXMLReader.parse(Data(repeating: 0x20, count: MetadataXMLReader.maximumFileBytes + 1))
    }
    let deep = String(repeating: "<x>", count: 129) + String(repeating: "</x>", count: 129)
    #expect(throws: MetadataReadError.self) { try MetadataXMLReader.parse(Data(deep.utf8)) }
}

@Test func metadataFilterPreservesUnknownMembership() throws {
    let known = ResourceFilter.resource(id: "LLS:A")
    let unknown = ResourceFilter.unknown(XMLNode(name: "category", attributes: ["name": "Bible"]))
    #expect(ResourceFilter.any([known, unknown]).contains(resourceID: "LLS:A") == true)
    #expect(ResourceFilter.any([known, unknown]).contains(resourceID: "LLS:B") == nil)
    #expect(ResourceFilter.all([known, unknown]).contains(resourceID: "LLS:B") == false)
    #expect(ResourceFilter.not(known).contains(resourceID: "LLS:A") == false)
}

@Test func metadataProjectsDocumentsWithoutExecutingStyles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixtures: [String: String] = [
        "relation.lbxras": #"<lbx-resource-association name="Pair" category="ResourceAssociations" guid="ROOT"><header><title xml:lang="es">Pareja</title></header><association priority="90" type="parallel"><resource guid="LLS:A"/><resource guid="LLS:B"/></association></lbx-resource-association>"#,
        "old.lbxras": #"<lbx-resource-association name="Old"><!-- This resource association has been made obsolete. --></lbx-resource-association>"#,
        "group.lbxcol": #"<lbx-resource-collection name="Subset" category="DataFiles/Collections"><resource-filter><or><resource resource-id="LLS:A"/><resource resource-id="LLS:B"/></or></resource-filter></lbx-resource-collection>"#,
        "mark.lbxvmp": ##"<lbx-visual-markup-palette name="Marks"><palette-styles><palette-style name="Wave"><markup-style><line pos="underline" type="smooth-wavy" color="#ff7f00"/><image content-type="image/bmp">Qk0=</image></markup-style></palette-style></palette-styles></lbx-visual-markup-palette>"##,
        "copy.lbxcbv": #"<lbx-copy-bible-verses-style name="Export"><options><option name="CharacterFormatting">false</option></options><templates><template name="BeforeVerse"><pattern xml:space="preserve">^v </pattern><format name="Bold"/><format name="Superscript">true</format></template></templates><languages><language name="he">Hebrew-LatinLogos</language></languages></lbx-copy-bible-verses-style>"#
    ]
    for (name, xml) in fixtures { try Data(xml.utf8).write(to: directory.appendingPathComponent(name)) }
    try Data([0x4c, 0x54, 0x45, 0x53, 0, 0, 1, 1]).write(to: directory.appendingPathComponent("opaque.lbxdtp"))
    // A book/license backup is outside metadata scope, even if it starts LTES.
    try Data([0x4c, 0x54, 0x45, 0x53]).write(to: directory.appendingPathComponent("book.lbxlls"))
    let snapshot = try MetadataImporter.inspectDirectory(at: directory)
    #expect(snapshot.parsedDocumentCount == 5)
    #expect(snapshot.opaqueFileCount == 1)
    #expect(snapshot.warnings.isEmpty)
    let pair = try #require(snapshot.associations.first { $0.name == "Pair" })
    #expect(pair.title == "Pareja")
    #expect(pair.id == "ResourceAssociations:Pair")
    #expect(pair.groups.first?.guid == nil)
    #expect(pair.groups.first?.priority == 90)
    #expect(pair.groups.first?.type == "parallel")
    #expect(pair.resourceIDs == ["LLS:A", "LLS:B"])
    #expect(snapshot.associations.first { $0.name == "Old" }?.definitionState == .obsoletePlaceholder)
    let collection = try #require(snapshot.collections.first)
    #expect(collection.resourceIDs == ["LLS:A", "LLS:B"])
    #expect(collection.contains(resourceID: "LLS:B") == true)
    #expect(collection.contains(resourceID: "LLS:C") == false)
    #expect(snapshot.palettes.first?.styles.first?.markup?.children.first?.attributes["type"] == "smooth-wavy")
    let style = try #require(snapshot.copyStyles.first)
    #expect(style.templates.first?.pattern == "^v ")
    #expect(style.templates.first?.formats.first?.value == nil)
    #expect(style.templates.first?.formats.last?.value == "true")
    #expect(style.languages["he"] == "Hebrew-LatinLogos")
    let copy = try JSONDecoder().decode(MetadataSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(copy.associations == snapshot.associations)
    #expect(copy.collections == snapshot.collections)
    #expect(copy.copyStyles == snapshot.copyStyles)
}

/// Private integration validation is opt-in; published tests contain no books.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONIX_METADATA_VALIDATION_ROOT"] != nil))
func metadataOriginalCorpus() throws {
    guard let source = ProcessInfo.processInfo.environment["LIBRONIX_METADATA_VALIDATION_ROOT"] else { return }
    let root = URL(fileURLWithPath: source, isDirectory: true)
    let snapshot = try MetadataImporter.inspectDirectory(at: root)
    #expect(snapshot.parsedDocumentCount == 78)
    #expect(snapshot.associations.count == 53)
    #expect(snapshot.associations.reduce(0) { $0 + $1.groups.count } == 49)
    #expect(snapshot.associations.filter { $0.definitionState == .obsoletePlaceholder }.count == 4)
    #expect(snapshot.associations.reduce(0) { $0 + $1.resourceIDs.count } == 1_116)
    #expect(snapshot.collections.count == 14)
    #expect(snapshot.collections.reduce(0) { $0 + $1.resourceIDs.count } == 202)
    #expect(snapshot.palettes.count == 5)
    #expect(snapshot.palettes.reduce(0) { $0 + $1.styles.count } == 82)
    #expect(snapshot.copyStyles.count == 6)
    #expect(snapshot.opaqueFileCount == 830)
    #expect(snapshot.warnings.isEmpty)
    #expect(snapshot.copyStyles.first { $0.name == "Simple Paragraphs" }?.templates.first { $0.name == "BeforeVerse" }?.pattern == "^v ")
    if let output = ProcessInfo.processInfo.environment["LIBRONIX_METADATA_VALIDATION_OUTPUT"] {
        let report: [String: Any] = [
            "source": source, "scope": "Declarative metadata; excludes books and license backups",
            "parsedDocuments": snapshot.parsedDocumentCount, "associations": snapshot.associations.count,
            "associationGroups": snapshot.associations.reduce(0) { $0 + $1.groups.count },
            "obsoletePlaceholders": snapshot.associations.filter { $0.definitionState == .obsoletePlaceholder }.count,
            "associationResourceReferences": snapshot.associations.reduce(0) { $0 + $1.resourceIDs.count },
            "collections": snapshot.collections.count,
            "collectionResourceReferences": snapshot.collections.reduce(0) { $0 + $1.resourceIDs.count },
            "palettes": snapshot.palettes.count,
            "paletteStyles": snapshot.palettes.reduce(0) { $0 + $1.styles.count },
            "copyStyles": snapshot.copyStyles.count, "opaqueMetadataFiles": snapshot.opaqueFileCount,
            "warnings": snapshot.warnings, "languageMode": "Swift 6", "readOnlyOriginals": true
        ]
        let destination = URL(fileURLWithPath: output).standardizedFileURL
        guard !destination.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            Issue.record("El reporte de validación no puede escribirse dentro del origen")
            return
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
    }
}
