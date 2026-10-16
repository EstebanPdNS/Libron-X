import Foundation
import Testing
@testable import LibronixCore

struct LibronixTopicIndexDeclarationTests {
    @Test func namesAndLanguagesRemainSeparateFromTextIndexesAndArticleTitles() throws {
        let xml = try MetadataXMLReader.parse(Data("""
        <resource><metadata><indexes>
          <index type="text" name="text"/>
          <index type="topic" name="topics"><language name="es"/><language name="en"/></index>
          <index type="topic" name="city"><language name="en"/><language name="en"/></index>
          <index type="topic" name="water"/>
          <index type="topic"/><index type="topic" name=""/>
          <index type="Topic" name="unvalidated"/>
        </indexes></metadata><title>Not a topic</title></resource>
        """.utf8))
        let declarations = LibronixTopicIndexDeclaration.read(from: xml)
        #expect(declarations.map(\.name) == ["topics", "city", "water"])
        #expect(declarations.map(\.languages) == [["es", "en"], ["en", "en"], []])
        #expect(try JSONDecoder().decode([LibronixTopicIndexDeclaration].self,
            from: JSONEncoder().encode(declarations)) == declarations)
    }
    @Test func unrelatedNestedDeclarationsDoNotInventCapabilities() throws {
        for text in ["<resource/>", "<resource><indexes><index type='topic' name='topics'/></indexes></resource>",
            "<resource><metadata><title><index type='topic' name='topics'/></title></metadata></resource>"] {
            #expect(try LibronixTopicIndexDeclaration.read(from: MetadataXMLReader.parse(Data(text.utf8))).isEmpty)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"] != nil))
    func actualDeclarationsCoverNamedMapIndexesAndMultilingualDictionariesWithoutMutatingOriginals() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_BIBLE_SYNC_CORPUS"]))
        let expected: [(String, [String], Set<String>)] = [
            ("17cual.lbxlls", ["topics"], ["es"]),
            ("DXMAPSET.lbxlls", ["topics", "water", "city", "region", "feature"], ["en"]),
            ("MISTRANS.lbxlls", ["author", "topics"], ["es"]),
            ("STRDICTES.lbxlls", ["topics"], ["el", "he", "x-arc", "es", "x-tl"]),
            ("rvr60.lbxlls", [], [])
        ]
        for (name, names, languages) in expected {
            let url = root.appendingPathComponent(name), before = try LegacyGraphicsService.fileStamp(url)
            let indexes = try LibronixBookArchive.inspect(at: url).metadata().declaredTopicIndexes
            #expect(indexes.map(\.name) == names)
            #expect(Set(indexes.flatMap(\.languages)) == languages)
            #expect(try LegacyGraphicsService.fileStamp(url) == before)
        }
    }
}
