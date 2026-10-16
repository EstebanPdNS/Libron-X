import Foundation
import Testing
@testable import LibronixCore

struct LibronixOEBTests {
    private func words(_ values: [UInt32]) -> Data {
        Data(values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
    }
    private func tables() -> (Data, Data) {
        let names = ["Title.html", "Chapter.html"]
        var filePool = Data(), fileRows = Data()
        for (ordinal, name) in names.enumerated() {
            let bytes = (name + "\0").data(using: .utf16LittleEndian)!
            fileRows += words([UInt32(filePool.count), UInt32(bytes.count), UInt32(1 - ordinal)]); filePool += bytes
        }
        let files = Data("LOEF".utf8) + words([0x01000000,12,2,48,0]) + fileRows + filePool
        var titles = Data(), anchors = Data(), rows = Data()
        for i in 0..<3 {
            let title = ["Owned title", "Chapter α", "Child 😀"][i].appending("\0").data(using: .utf16LittleEndian)!
            let fragment = "anchor_\(i)\0".data(using: .utf16LittleEndian)!
            rows += words([UInt32(i), i == 0 ? 0 : 1, i == 2 ? 1 : .max, i == 0 ? 1 : .max,
                           i == 2 ? 3 : 0, UInt32(titles.count), UInt32(title.count), UInt32(anchors.count), UInt32(fragment.count)])
            titles += title; anchors += fragment
        }
        let articles = Data("LOEA".utf8) + words([0x01000000,12,3,140,UInt32(140 + titles.count),0,2]) + rows + titles + anchors
        return (files, articles)
    }
    @Test func preservesPhysicalFileOrderSharedPageFragmentsAndIndependentHeadingLevel() throws {
        let (files, articles) = tables()
        let directory = try LibronixOEBDirectory(fileTable: files, articleTable: articles)
        #expect(directory.nameOrder == [1,0])
        #expect(directory.articles.map(\.path) == ["Title.html", "Chapter.html", "Chapter.html"])
        #expect(directory.articles.map(\.title) == ["Owned title", "Chapter α", "Child 😀"])
        #expect(directory.articles[2].parent == 1 && directory.articles[2].depth == 1)
        #expect(directory.articles[2].sourceHeadingLevel == 3)
    }
    @Test func rejectsTruncatedTablesInvalidPoolsCyclesInvalidFileIDsAndUTF16() throws {
        let (files, articles) = tables()
        for at in [0,4,8,12,16,24,28,32] {
            var data = files; data.replaceSubrange(at..<(at + 4), with: words([.max]))
            #expect(throws: LibronixBookError.self) { try LibronixOEBDirectory(fileTable: data, articleTable: articles) }
        }
        for (at, value): (Int, UInt32) in [(4,9),(8,0),(12,.max),(16,1),(20,.max),(24,1),(28,1),(36,5),(40,0),(44,0),(60,1),(64,1)] {
            var data = articles; data.replaceSubrange(at..<(at + 4), with: words([value]))
            #expect(throws: LibronixBookError.self) { try LibronixOEBDirectory(fileTable: files, articleTable: data) }
        }
        for count in [0,1,11,23,47] {
            #expect(throws: LibronixBookError.self) { try LibronixOEBDirectory(fileTable: Data(files.prefix(count)), articleTable: articles) }
        }
        var badUTF16 = articles; badUTF16[140] = 0; badUTF16[141] = 0xd8
        #expect(throws: LibronixBookError.self) { try LibronixOEBDirectory(fileTable: files, articleTable: badUTF16) }
    }
    @Test func confinesMemberURLsToOneOriginAndUnambiguousCaseInsensitiveArchivePaths() throws {
        let (files, articles) = tables(), directory = try LibronixOEBDirectory(fileTable: files, articleTable: articles)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let members = ["Title.html":Data(),"Chapter.html":Data(),"Images/Owned map.png":Data([1,2])]
        let book = try LibronixOEBBook(source: source, directory: directory, members: members)
        #expect(book.path(for: book.url(path: "images/owned map.PNG")) == "Images/Owned map.png")
        #expect(book.article(for: book.url(path: "CHAPTER.HTML", fragment: "anchor_2"))?.ordinal == 2)
        #expect(book.article(for: book.url(path: "Title.html"))?.ordinal == 0)
        for url in ["file:///Title.html", "https://\(book.origin)/Title.html", "libronx-oeb://foreign/Title.html", "libronx-oeb://\(book.origin)/%2e%2e/Title.html", "libronx-oeb://user@\(book.origin)/Title.html", "libronx-oeb://\(book.origin)/Title.html?x=1"] {
            #expect(book.path(for: try #require(URL(string: url))) == nil)
        }
        var collision = members; collision["TITLE.html"] = Data()
        #expect(throws: LibronixBookError.invalidDirectory) { try LibronixOEBBook(source: source, directory: directory, members: collision) }
        try Data([2,3]).write(to: source)
        #expect(throws: LibronixBookError.sourceChanged) { try book.verifySource() }
    }
}
