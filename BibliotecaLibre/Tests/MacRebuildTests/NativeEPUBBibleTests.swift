import AppKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct NativeEPUBBibleTests {
    @Test func onlyEPUBsWithVerifiedNativeVerseAddressesEnterBibleVersionChoices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var metadata = LibronMetadata(title: "Authored Bible fixture", origin: "EPUB")
        metadata.resourceType = "Biblia"
        var resources: [LibraryResource] = []
        for index in 0..<3 {
            let source = root.appendingPathComponent("fixture-\(index).epub")
            try Data("Authored immutable source \(index)".utf8).write(to: source)
            let input = LibraryResource(location: source, title: metadata.title, byteCount: Int64(try Data(contentsOf: source).count),
                format: .epub, support: .metadataOnly, provenance: .libronixMetadata, libron: metadata)
            let package = try LibronPackage.create(input, in: root.appendingPathComponent("Library"), backup: false)
            if index < 2 {
                let folder = package.appendingPathComponent("normalized")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let db = try LibronNativeDatabase(folder.appendingPathComponent("reader.sqlite"), create: true)
                if index == 0 { try db.add(reference: "Ge 1:1", ordinal: 0, offset: 0) }
                try db.finish()
                try LibronPackage.registerNormalizedContent(in: package)
            }
            resources.append(try LibronPackage.read(package, verify: true).1)
        }
        let choices = try await BibleVersionCatalog().versions(in: resources, observed: [])
        #expect(choices.map(\.id) == [resources[0].id])
    }

    @Test func inspectedStudyBibleUsesNativeChaptersNotesImagesAndReferenceDestinations() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_VERIFY_NKJV_NATIVE"] else { return }
        let root = URL(fileURLWithPath: path)
        let title = ProcessInfo.processInfo.environment["LIBRONX_VERIFY_NKJV_TITLE"] ?? "The NKJV Study Bible: Second Edition"
        let expectedImages = Int(ProcessInfo.processInfo.environment["LIBRONX_VERIFY_NKJV_IMAGES"] ?? "110")!
        let resource = try #require(try LibronCatalog.load(from: root).resources.first { $0.title == title })
        _ = try LibronPackage.read(try #require(resource.packageLocation), verify: true)
        let reader = LibronNativeReader()
        let header = try #require(try await reader.header(resource))
        #expect(header.profile == "structured-text")
        let books = try await BibleChapterCatalog().books(in: resource)
        #expect(books.count == 66 && books.reduce(0) { $0 + $1.chapters.count } == 1189)
        let searchReader = WorkspaceSearchReader()
        let prepared = try await searchReader.prepare(resource)
        #expect(prepared.availableFields?.contains(.bibleText) == true)
        let searched = try await searchReader.read(resource, article: prepared.articles[0], prepared: prepared)
        #expect(searched.bibleVerses.count == 31 && searched.referenceAnchors.isEmpty)
        #expect(searched.fieldDirectory?.regions[.bibleText]?.count == 31)
        let db = try LibronNativeDatabase(try #require(LibronNativeReader.location(resource)))
        var verseCount = 0, imageCount = 0, linkCount = 0, richSections = 0
        var samples: [LegacyInlineLink] = []
        for ordinal in 0..<header.sectionCount {
            let section = try JSONDecoder().decode(LibronNativeSection.self, from: #require(try db.get("section/\(ordinal)")))
            #expect(section.content?.plainText == section.text)
            let content = try #require(section.content)
            // Independently decode all RTF with AppKit, checking every UTF-16 position.
            let rtf = try #require(content.richTextRTF)
            let imported = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            try #require(imported.string == section.text, "RTF projection differs in section \(ordinal)")
            richSections += 1
            for anchor in content.anchors {
                let reference = try #require(anchor.reference)
                let resolved = try #require(try db.resolve(reference))
                #expect(resolved.ordinal == ordinal && resolved.offset == anchor.characterOffset)
                verseCount += 1
            }
            for asset in section.graphics {
                #expect(ReaderImageRenderer.decode(asset.data) != nil)
                #expect((section.text as NSString).character(at: asset.graphic.objectCharacterOffset) == 0xfffc)
                imageCount += 1
            }
            for link in section.inlineLinks {
                let destination = try ReaderLinkPreviewState.destination(for: link, resource: resource)
                if let reference = destination.reference { #expect(try db.resolve(reference) != nil) }
                else { #expect((0..<header.sectionCount).contains(destination.ordinal)) }
                linkCount += 1
            }
            if ordinal == 0 { samples = section.inlineLinks }
        }
        #expect(verseCount == 31102 && imageCount == expectedImages && richSections == header.sectionCount)
        let choices = try await BibleVersionCatalog().versions(in: [resource], observed: [])
        #expect(choices.map(\.id) == [resource.id])
        for book in books {
            for chapter in book.chapters {
                let page = try await reader.read(resource, .init(ordinal: 0, reference: book.reference(chapter: chapter)))
                #expect(page.oeb == nil && page.content != nil && page.selection != nil)
                #expect(ReaderBibleIndex(anchors: page.content?.anchors ?? [], textLength: page.text.utf16.count).entries.count > 0)
            }
        }
        for link in samples.prefix(8) {
            let destination = try ReaderLinkPreviewState.destination(for: link, resource: resource)
            let page = try await reader.read(resource, destination)
            #expect(page.oeb == nil && !page.text.isEmpty)
        }
        let verse = try await reader.read(resource, .init(ordinal: 0, reference: "Jn 3:16"))
        #expect(verse.text.contains("For God so loved the world"))
        let passage = try await reader.read(resource, .init(ordinal: 0, reference: "Ge 1:31", endReference: "Ge 2:2"))
        #expect(passage.passageParts.count == 2)
        print("NKJV native corpus: \(richSections) native RTF sections, \(verseCount) verses, 1189 chapters, \(imageCount) decoded images, \(linkCount) checked links")
    }
    @Test func fullColorStudyTablesAndCommentaryRolesRemainNative() throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_VERIFY_STUDY_FEATURES"] else { return }
        let resource = try #require(try LibronCatalog.load(from: URL(fileURLWithPath: path)).resources.first { $0.title == "NKJV Study Bible, Full-Color" })
        let db = try LibronNativeDatabase(try #require(LibronNativeReader.location(resource)))
        let header = try JSONDecoder().decode(LibronNativeHeader.self, from: #require(try db.get("header")))
        var tables = 0, cells = 0, rows = 0, comments = 0
        for ordinal in 0..<header.sectionCount {
            let section = try JSONDecoder().decode(LibronNativeSection.self, from: #require(try db.get("section/\(ordinal)")))
            comments += section.inlineLinks.filter { $0.role == .studyCommentary }.count
            guard let data = section.content?.richTextRTF,
                  data.range(of: Data(#"\trowd"#.utf8)) != nil else { continue }
            let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            var foundTables: Set<ObjectIdentifier> = [], foundCells: Set<ObjectIdentifier> = []
            var rowCounts: [ObjectIdentifier: Int] = [:]
            text.enumerateAttribute(.paragraphStyle, in: .init(location: 0, length: text.length)) { value, _, _ in
                for case let cell as NSTextTableBlock in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                    let id = ObjectIdentifier(cell.table)
                    foundTables.insert(id); foundCells.insert(ObjectIdentifier(cell))
                    rowCounts[id] = max(rowCounts[id] ?? 0, cell.startingRow + cell.rowSpan)
                }
            }
            tables += foundTables.count; cells += foundCells.count; rows += rowCounts.values.reduce(0, +)
            #expect(text.string == section.text)
        }
        #expect(tables == 75 && cells == 2445 && rows == 920)
        #expect(comments == 15007)
        print("Full-color study features: \(tables) AppKit tables, \(rows) rows, \(cells) cells, \(comments) explicit verse-commentary links")
    }

}
