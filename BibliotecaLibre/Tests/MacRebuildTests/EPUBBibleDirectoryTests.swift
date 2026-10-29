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
            #expect(archive.metadata.resourceType == "Biblia")
            let directory = try EPUBBibleDirectory(book: archive.book)
            #expect(directory.entries.first(where: { $0.fragment == "v01001001" })?.verse == 1)
            #expect(directory.entries.contains { $0.fragment == "v01001031" })
            #expect(directory.entries.contains { $0.fragment == "v01002001" })
            let passages = directory.entries.filter { ["v01001001", "v01001002"].contains($0.fragment) }
            let projection = try EPUBBibleText.read(book: archive.book, entries: passages)
            let text = projection.mapValues { $0.filter { $0.noteTarget == nil }.map(\.text).joined() }
            #expect(text["v01001001"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "In the beginning God created the heavens and the earth.")
            #expect(text["v01001002"]?.contains("The earth was without form, and void") == true)
            #expect(text["v01001002"]?.contains("Word Study") == false)
            let marker = try #require(projection["v01001001"]?.first { $0.noteTarget != nil })
            let note = try #require(EPUBBibleText.footnotes(book: archive.book, pieces: [marker])[marker.noteKey])
            #expect(note.text.contains("102:25"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_EPUB_BIBLES"] != nil)) @MainActor
    func copiesOriginalStudyBiblePassagesAndNotes() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_EPUB_BIBLES"]))
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "epub" && $0.path.localizedCaseInsensitiveContains("NKJV") }
        #expect(urls.count == 2)
        for url in urls {
            let resource = LibraryResource(location: url, title: "Study Bible", byteCount: 0, format: .epub, support: .metadataOnly, provenance: .fileName)
            let document = try await WorkspaceBibleCopy.prepare(resource, passage: .parse("Ge 1:1-3"), includeFootnotes: true)
            #expect(document.verses.count == 3)
            #expect(document.verses[0].text.trimmingCharacters(in: .whitespacesAndNewlines) == "In the beginning God created the heavens and the earth.")
            #expect(document.verses[1].text.contains("The earth was without form, and void"))
            #expect(document.verses[1].fragments.contains { $0.text == "was" && $0.style?.font.italic == true })
            #expect(document.footnotes.contains { $0.text.contains("102:25") })
            var style = BibleCopyOutputStyle(); style.copyFootnotes = true
            let formatted = try BibleCopyFormatter.format(document, style: style)
            #expect(formatted.bodyText.contains("beginning") && formatted.bodyText.contains("heavens and the earth."))
            #expect(formatted.notes.contains { $0.text.contains("102:25") })
            style.paragraphs = .sourceParagraphs
            let sourceParagraphs = try BibleCopyFormatter.format(document, style: style)
            #expect(sourceParagraphs.bodyText.contains("beginning"))
            let span = try await EPUBBibleCopy.prepare(resource, passage: .parse("Ge 1:31-2:1"), includeFootnotes: false)
            #expect(span.verses.map(\.address.key) == ["ge 1:31", "ge 2:1"])
            let chapter = try await EPUBBibleCopy.prepare(resource, passage: .parse("Ge 1"), includeFootnotes: false)
            #expect(chapter.verses.count == 31)
            #expect(chapter.verses[7].text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("And God called"))
            let chapterWithNotes = try await EPUBBibleCopy.prepare(resource, passage: .parse("Ge 1"), includeFootnotes: true)
            #expect(chapterWithNotes.verses.count == 31 && chapterWithNotes.footnotes.count > 10)
            let john = try await EPUBBibleCopy.prepare(resource, passage: .parse("John 3:16"), includeFootnotes: false)
            #expect(john.verses[0].text.contains("God so loved the world"))
            let psalm = try await EPUBBibleCopy.prepare(resource, passage: .parse("Ps 23:1-6"), includeFootnotes: false)
            #expect(psalm.verses.count == 6 && psalm.verses[0].text.contains("shepherd"))
        }
    }
}
