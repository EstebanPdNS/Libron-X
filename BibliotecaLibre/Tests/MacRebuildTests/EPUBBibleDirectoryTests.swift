import Foundation
import LibronixCore
import Testing
@testable import MacRebuild

struct EPUBBibleDirectoryTests {
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
        }
    }
}
