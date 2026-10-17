import Foundation
import Testing
@testable import LibronixCore

struct EPUBArchiveTests {
    @Test(arguments: ["authored-stored", "authored-deflate"])
    func storedAndDeflatedEPUBPreserveSpineMetadataAndUnicode(name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "epub", subdirectory: "Fixtures"))
        let epub = try EPUBArchive(url)
        #expect(epub.metadata.title == "Authored EPUB" && epub.metadata.languages == ["es"])
        #expect(epub.metadata.authors == ["Fixture Author"])
        #expect(epub.book.directory.articles.map(\.path) == ["Book/one.xhtml", "Book/two.xhtml"])
        #expect(String(data: try #require(epub.book.members["Book/one.xhtml"]), encoding: .utf8)?.contains("Amor 😀") == true)
        try epub.book.verifySource()
    }
    @Test func checksumCorruptionIsRejectedBeforeRendering() throws {
        let input = try #require(Bundle.module.url(forResource: "authored-stored", withExtension: "epub", subdirectory: "Fixtures"))
        var data = try Data(contentsOf: input)
        let span = try #require(data.range(of: Data("Amor".utf8))); data[span.lowerBound] = 0x42
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: target) }; try data.write(to: target)
        #expect(throws: LibronError.self) { try EPUBArchive(target) }
    }
}
