import AppKit
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct LibronixBookCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_BOOK_CORPUS"] != nil))
    func actualLibronixContainersExposeMetadataAndNativeStyledPages() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_BOOK_CORPUS"]))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { ["lbxlls", "lbxoeb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var inventory: [[String: Any]] = [], failures: [String] = []
        for url in files {
            do {
                let archive = try LibronixBookArchive.inspect(at: url), metadata = try archive.metadata()
                inventory.append(["file": url.lastPathComponent, "profile": archive.profile,
                    "title": metadata.title ?? "", "identifier": metadata.identifier ?? "",
                    "entries": archive.entries.map { ["path": $0.path, "bytes": $0.length] },
                    "hasLSF": archive.entries.contains { $0.path.lowercased().hasSuffix(".lsf") }])
            } catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        if let output = ProcessInfo.processInfo.environment["LIBRONX_BOOK_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: ["containers": inventory, "failures": failures], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
        print("Libronix actual archive metadata: \(inventory.count)/\(files.count); failures=\(failures)")
        #expect(!inventory.isEmpty && failures.isEmpty)
        for name in ["ESPOSHMBRNV.lbxlls", "EASTONS.lbxlls", "RVR60NTRI.lbxlls", "rvr60.lbxlls", "LBLA95.lbxlls", "NVI.lbxlls", "KJV.lbxlls", "ESV.lbxlls", "NCV.lbxlls", "TEOLOGIA.lbxlls", "UTMOST.lbxlls"] {
            let url = root.appendingPathComponent(name), before = try LegacyGraphicsService.fileStamp(url)
            let metadata = try LibronixBookArchive.inspect(at: url).metadata()
            let resource = LibraryResource(location: url, title: metadata.title ?? name, byteCount: Int64(before.size),
                format: .libronixLLS, support: .metadataOnly, provenance: .libronixMetadata, legacyIdentifier: metadata.identifier)
            let inner = try await LibronixBookService.shared.prepare(resource)
            if name == "rvr60.lbxlls" {
                let layout = try LegacyResourceReader.inspect(lsfURL: inner.location).lsf
                let directory = try await LegacyContentService().directory(inner.location, indexURL: inner.indexLocation, allowUnavailableIndexBlocks: true)
                print("Modern RV60 contents: \(directory.entries.prefix(5).map { $0.displayTitle + ":" + String($0.sectionOrdinal) })")
                print("Modern RV60 titled contents: \(directory.entries.filter { $0.title != nil }.prefix(8).map { $0.displayTitle + ":" + String($0.sectionOrdinal) })")
                let first = try #require(directory.entries.first { $0.title?.isEmpty == false })
                let opened = try await ReaderSession.read(resource, .init(ordinal: 0, prefersContentsStart: true))
                #expect(opened.destination.ordinal == first.sectionOrdinal && opened.destination.prefersContentsStart == nil)
                #expect(opened.entries.first?.ordinal == first.sectionOrdinal)
                #expect(opened.entries.allSatisfy { entry in directory.entries.contains { $0.id == entry.id && $0.title != nil } })
                let chapter = try #require(directory.entries.first { $0.title == "Capítulo 1" })
                let chapterPage = try await ReaderSession.read(resource, .init(ordinal: chapter.sectionOrdinal))
                #expect(chapterPage.text.utf16.count > 500 && chapterPage.typography != nil)
                #expect(ReaderTypography.render(text: chapterPage.text, content: chapterPage.content, typography: chapterPage.typography).text.string == chapterPage.text)

                print("Modern RV60 blocks: \(layout.blocks.map { $0.tag + ":" + String($0.offset) + ":" + String($0.length) })")
            }
            let index = try LegacyContentReader.inspectSections(lsfURL: inner.location)
            let descriptor = try #require(index.sections.first)
            let handle = try FileHandle(forReadingFrom: inner.location)
            try handle.seek(toOffset: descriptor.payloadOffset)
            let raw = try #require(try handle.read(upToCount: Int(descriptor.storedLength))); try handle.close()
            let decoded = descriptor.mode == 0 ? raw : try LegacyContentReader.decompressDCL(raw, expectedLength: Int(descriptor.decodedLength))
            print("Book framing \(name): payloadOffset=\(descriptor.payloadOffset); header=\(decoded.prefix(44).map { String(format: "%02x", $0) }.joined())")
            if let output = ProcessInfo.processInfo.environment["LIBRONX_BOOK_RECEIPT"] {
                try decoded.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(name + ".article0.bin"))
            }
            let samples = name == "RVR60NTRI.lbxlls" ? [0] : Set([0, min(1, index.sections.count - 1), index.sections.count / 2]).sorted()
            for ordinal in samples {
                let page = try await ReaderSession.read(resource, .init(ordinal: ordinal))
                let display = ReaderTypography.render(text: page.text, content: page.content, typography: page.typography)
                #expect(page.typography != nil && display.text.string == page.text)
                #expect(display.text.length == page.text.utf16.count)
                if !page.text.isEmpty { #expect(display.text.attribute(.font, at: 0, effectiveRange: nil) is NSFont) }
                #expect(try LegacyGraphicsService.fileStamp(url) == before)
                print("Libronix native page: \(name)[\(ordinal)]; articles=\(page.sectionCount); styles=\(page.typography?.characterStyles.count ?? 0)/\(page.typography?.paragraphStyles.count ?? 0); UTF16=\(display.text.length); warnings=\(display.warnings)")
            }
        }
    }
}
