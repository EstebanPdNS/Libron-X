import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

struct EPUBBibleDirectoryTests {
    @Test func rejectsDuplicateVerseAnchors() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("owned".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let directory = try LibronixOEBDirectory(files: ["chapter.xhtml"], titles: ["Owned"])
        let html = Data("<html><body><span id='v01001001'/><span id='v01001001'/></body></html>".utf8)
        let book = try LibronixOEBBook(source: source, directory: directory, members: ["chapter.xhtml": html])
        #expect(throws: BibleCopyError.incompleteSource) { try EPUBBibleDirectory(book: book) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_EPUB_BIBLES"] != nil))
    func locatesOriginalStudyBibleAnchors() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_EPUB_BIBLES"]))
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "epub" && $0.path.localizedCaseInsensitiveContains("NKJV") }
        #expect(urls.count == 2)
        for url in urls {
            let archive = try EPUBArchive(url)
            let directory = try EPUBBibleDirectory(book: archive.book)
            #expect(directory.entries.first(where: { $0.fragment == "v01001001" })?.verse == 1)
            #expect(directory.entries.contains { $0.fragment == "v01001031" })
            #expect(directory.entries.contains { $0.fragment == "v01002001" })
            let passages = directory.entries.filter { ["v01001001", "v01001002"].contains($0.fragment) }
            let text = try EPUBBibleText.read(book: archive.book, entries: passages)
            #expect(text["v01001001"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "In the beginning God created the heavens and the earth.")
            #expect(text["v01001002"]?.contains("The earth was without form, and void") == true)
            #expect(text["v01001002"]?.contains("Word Study") == false)
        }
    }
}
