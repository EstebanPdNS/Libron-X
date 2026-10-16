import AppKit
import Foundation
import Testing
@testable import LibronixCore
@testable import MacRebuild

struct ReaderPassagePartsTests {
    private func content(_ text: String, ordinal: Int) -> LegacySectionContent {
        .init(descriptor: .init(ordinal: ordinal, headerOffset: 0, payloadOffset: 0, storedLength: 0, decodedLength: 0, mode: 0, codecWord: nil),
              plainText: text, runs: [], expectedCharacterCount: UInt32(text.utf16.count), recognizedFormat: "authored",
              paragraphs: [], anchors: [], markers: [], graphics: [], warnings: [], paragraphDocuments: nil)
    }
    private func pages() throws -> [ReaderPage] {
        let first = content("before\n12 Alpha\n13 Beta\n", ordinal: 4)
        let last = content("14 Gamma\n15 Delta\nafter\n", ordinal: 5)
        let parts = [
            try ReaderPassagePartSource.validatedPart(content: first, start: 7, end: first.plainText.utf16.count, reference: "1Jn 3:12"),
            try ReaderPassagePartSource.validatedPart(content: last, start: 0, end: 18, reference: "1Jn 3:14")
        ]
        return parts.map { part in
            ReaderPage(destination: .init(ordinal: part.ordinal, reference: part.reference, endReference: "1Jn 3:15", passageStartReference: "1Jn 3:12"),
                       text: part.content.plainText, sectionCount: 10, selection: part.selection, content: part.content, passageParts: parts)
        }
    }
    private func resource() -> LibraryResource {
        .init(location: URL(fileURLWithPath: "/authored/edition.LSF"), title: "Authored", byteCount: 0,
              format: .legacyLSF, support: .metadataOnly, provenance: .fileName)
    }
    @Test func malformedSavedPassageContextsCannotBecomeReaderRequests() throws {
        #expect(throws: RebuildError.self) { try ReaderDestination(ordinal: 0, passageStartReference: "Jn 1:1").validate() }
        #expect(throws: RebuildError.self) { try ReaderDestination(ordinal: 0, endReference: "Jn 1:2").validate() }
        #expect(throws: RebuildError.self) { try ReaderDestination(ordinal: 0, reference: "Jn 1:1", endReference: "not a reference").validate() }
        #expect(throws: RebuildError.self) { try ReaderDestination(ordinal: 0, requiredEdition: "file:///own").validate() }
        try ReaderDestination(ordinal: 0, reference: "local-oeb-fragment").validate()
        try ReaderDestination(ordinal: 10, reference: "Jn 1:1", endReference: "Jn 1:2", requiredEdition: "RVR95", passageStartReference: "Jn 1:1").validate()
    }
    @Test func partsRetainTheirOriginalTextAndLocalRangesAndRejectInvalidUnicodeOrReferences() throws {
        let values = try pages()
        #expect(values[0].text == "before\n12 Alpha\n13 Beta\n")
        #expect(values[1].text == "14 Gamma\n15 Delta\nafter\n")
        #expect(values[1].passagePartIndex == 1 && values[1].passageDestination(at: 0)?.ordinal == 4)
        #expect(values[1].passageDestination(at: 0)?.passageStartReference == "1Jn 3:12")
        #expect(values[0].passageDestination(at: -1) == nil && values[1].passageDestination(at: 2) == nil)
        let emoji = content("😀 text", ordinal: 6)
        #expect(throws: RebuildError.self) { try ReaderPassagePartSource.validatedPart(content: emoji, start: 1, end: 3, reference: "Jn 1:1") }
        #expect(throws: RebuildError.self) { try ReaderPassagePartSource.validatedPart(content: emoji, start: 0, end: 2, reference: nil) }
        #expect(throws: RebuildError.self) { try ReaderPassagePartSource.validatedPart(content: emoji, start: 0, end: 99, reference: "Jn 1:1") }
    }
    @MainActor @Test func completeCopyRetainsBothPartsWhileAnExplicitSelectionStaysLocal() throws {
        let reader = ReaderSession(resource: resource())
        reader.page = try pages()[0]; reader.selectedRange = try #require(reader.page?.selection)
        #expect(!ReaderOutputActions.copiesExplicitSelection(reader))
        let complete = try ReaderOutputActions.document(reader)
        #expect(complete.string == "12 Alpha\n13 Beta\n14 Gamma\n15 Delta\n")
        #expect(!complete.string.contains("before") && !complete.string.contains("after"))
        reader.selectedRange = NSRange(location: 10, length: 5)
        #expect(ReaderOutputActions.copiesExplicitSelection(reader))
        #expect(try ReaderOutputActions.document(reader, selectionOnly: true).string == "Alpha")
        reader.page = try pages()[1]
        #expect(try ReaderOutputActions.document(reader).string == complete.string)
    }
    @MainActor @Test func joiningOutputRebasesInterlinearDrawingCoordinatesWithoutChangingItsText() throws {
        let word = NSAttributedString(string: "Word", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let glyph = ReaderInterlinearGlyph(range: NSRange(location: 0, length: 4), rows: [word], rowHeights: [18], scale: 1)
        let part = NSAttributedString(string: "Word", attributes: [.readerInterlinearUnit: glyph])
        let output = NSMutableAttributedString(string: "First")
        ReaderOutputActions.appendPassagePart(part, to: output)
        let installed = try #require(output.attribute(.readerInterlinearUnit, at: 6, effectiveRange: nil) as? ReaderInterlinearGlyph)
        #expect(output.string == "First\nWord" && installed.sourceRange == NSRange(location: 6, length: 4))
        #expect(glyph.sourceRange == NSRange(location: 0, length: 4) && installed.rows[0].string == "Word")
    }
    @MainActor @Test func partNavigationAndHistoryKeepTheCompleteRangeAndOriginalLocalSelection() async throws {
        let pages = try pages(), resource = resource()
        let reader = ReaderSession(resource: resource, loader: { _, destination in
            var value = try #require(pages.first { $0.destination.ordinal == destination.ordinal })
            value.destination = destination; return value
        })
        reader.load(pages[0].destination)
        for _ in 0..<100 where reader.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        reader.nextArticle()
        for _ in 0..<100 where reader.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reader.page?.destination.ordinal == 5 && reader.page?.destination.passageStartReference == "1Jn 3:12")
        #expect(reader.page?.destination.endReference == "1Jn 3:15" && reader.selectedRange == pages[1].selection)
        #expect(reader.history.count == 2 && reader.canGoBack)
        reader.goBack()
        for _ in 0..<100 where reader.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reader.page?.destination == pages[0].destination && reader.selectedRange == pages[0].selection)
        let saved = try JSONDecoder().decode(ReaderDestination.self, from: JSONEncoder().encode(try #require(reader.page).destination))
        #expect(saved.passageStartReference == "1Jn 3:12" && saved.endReference == "1Jn 3:15")
    }
    @MainActor @Test func previewCanVisitEveryPartWithoutChangingTheOriginatingReader() async throws {
        let values = try pages(), resource = resource()
        let preview = ReaderLinkPreviewState(loader: { _, destination in
            var result = values[destination.reference == "1Jn 3:14" ? 1 : 0]
            result.destination = destination.ordinal == 0 ? values[0].destination : destination
            return result
        })
        let reference = try #require(LegacyBibleLinkReference.parse("=r1Jn 3:12-15"))
        let link = LegacyInlineLink(range: .init(location: 0, length: 2), label: "12", sourceName: "=r1Jn 3:12-15", target: .bible(reference))
        preview.load(link, resource: resource)
        for _ in 0..<100 where preview.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(preview.page?.passagePartIndex == 0)
        preview.movePassage(by: 1)
        for _ in 0..<100 where preview.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(preview.page?.passagePartIndex == 1 && preview.page?.selection == values[1].selection)
        preview.movePassage(by: -1)
        for _ in 0..<100 where preview.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        #expect(preview.page?.passagePartIndex == 0 && preview.link == link)
        preview.cancel()
    }
}
