import AppKit
import Foundation
@testable import LibronixCore
import SwiftUI
import Testing
@testable import BibliotecaMac

@MainActor struct WindowAndReaderStateTests {
    @Test func windowsShareTheCatalogAndKeepSelectionFiltersAndReadersIndependent() async throws {
        let fixture = try ReaderFixture(documents: [["First window"], ["Second window"]])
        defer { fixture.remove() }
        let store = LibraryStore()
        store.snapshot = LibrarySnapshot(root: fixture.root, resources: fixture.resources,
            discoveredFiles: fixture.resources.count, importDurationSeconds: 0)
        let first = LibraryModel(store: store), second = LibraryModel(store: store)
        #expect(first.store === second.store)
        #expect(first.reader !== second.reader)
        first.selection = fixture.resources[0].id
        second.selection = fixture.resources[1].id
        first.searchText = "Synthetic 1"
        second.searchText = "Synthetic 2"
        first.reader.open(fixture.resources[0])
        second.reader.open(fixture.resources[1])
        try await settle(first.reader)
        try await settle(second.reader)
        #expect(first.selectedResource?.id == fixture.resources[0].id)
        #expect(second.selectedResource?.id == fixture.resources[1].id)
        #expect(first.visibleResources.map(\.id) == [fixture.resources[0].id])
        #expect(second.visibleResources.map(\.id) == [fixture.resources[1].id])
        #expect(first.reader.content?.plainText == "First window")
        #expect(second.reader.content?.plainText == "Second window")
        first.reader.findText = "First"
        first.reader.findNext()
        #expect(first.reader.highlightRange != nil)
        #expect(second.reader.highlightRange == nil)
        #expect(second.reader.findText.isEmpty)
        first.reader.cancelPendingRead()
        second.reader.cancelPendingRead()
    }

    @Test func aCorruptDestinationPreservesTheLastReadableArticleHistoryAndPosition() async throws {
        let fixture = try ReaderFixture(documents: [["First readable", nil, "Last readable"]])
        defer { fixture.remove() }
        let reader = ResourceReaderModel()
        reader.open(fixture.resources[0])
        try await settle(reader)
        reader.load(2)
        try await settle(reader)
        #expect(reader.ordinal == 2)
        #expect(reader.history.sections == [0, 2])
        let previousContent = reader.content, previousHistory = reader.history
        reader.load(1)
        try await settle(reader)
        #expect(reader.errorMessage != nil)
        #expect(reader.content == previousContent)
        #expect(reader.ordinal == 2)
        #expect(reader.sectionInput == "3")
        #expect(reader.history == previousHistory)
        #expect(UserDefaults.standard.integer(forKey: fixture.positionKey(0)) == 2)
        reader.goBack()
        try await settle(reader)
        #expect(reader.content?.plainText == "First readable")
        #expect(reader.ordinal == 0)
        #expect(reader.canGoForward)
        reader.goForward()
        try await settle(reader)
        #expect(reader.content?.plainText == "Last readable")
        #expect(reader.history.sections == [0, 2])
        reader.cancelPendingRead()
    }

    @Test func theLastRequestedDestinationWinsWithoutCommittingCanceledHistory() async throws {
        let fixture = try ReaderFixture(documents: [["Initial", "Superseded", "Latest"]])
        defer { fixture.remove() }
        let reader = ResourceReaderModel()
        reader.open(fixture.resources[0])
        try await settle(reader)
        // Both requests are issued in the same main-actor turn. The first task
        // must lose its right to commit before either read can update the view.
        reader.load(1)
        reader.load(2)
        try await settle(reader)
        #expect(reader.ordinal == 2)
        #expect(reader.content?.plainText == "Latest")
        #expect(reader.history.sections == [0, 2])
        #expect(reader.errorMessage == nil)
        #expect(UserDefaults.standard.integer(forKey: fixture.positionKey(0)) == 2)
        reader.cancelPendingRead()
    }

    @Test func openingAnotherResourceCancelsThePreviousSelection() async throws {
        let fixture = try ReaderFixture(documents: [["Superseded resource"], ["Current resource"]])
        defer { fixture.remove() }
        let reader = ResourceReaderModel()
        reader.open(fixture.resources[0])
        reader.open(fixture.resources[1])
        try await settle(reader)
        #expect(reader.content?.plainText == "Current resource")
        #expect(reader.history.sections == [0])
        #expect(reader.ordinal == 0)
        #expect(reader.sections.count == 1)
        #expect(reader.errorMessage == nil)
        reader.cancelPendingRead()
    }

    @Test func findUsesUTF16RangesWrapsAndPreservesDecodedUnicodeForCopy() async throws {
        let source = "🦉 Génesis — GENESIS\nfin"
        let fixture = try ReaderFixture(documents: [[source]])
        defer { fixture.remove() }
        let reader = ResourceReaderModel()
        reader.open(fixture.resources[0])
        try await settle(reader)
        reader.findText = "genesis"
        reader.findNext()
        #expect(reader.highlightRange == NSRange(location: 3, length: 7))
        reader.findNext()
        #expect(reader.highlightRange == NSRange(location: 13, length: 7))
        reader.findNext()
        #expect(reader.highlightRange == NSRange(location: 3, length: 7))
        #expect(reader.content?.plainText == source)
        reader.findText = "absent"
        reader.findNext()
        #expect(reader.highlightRange == NSRange(location: 3, length: 7))
        #expect(reader.findMessage != nil)
        #expect(reader.content?.plainText == source)
        reader.findText = "genesis"
        reader.findPrevious()
        #expect(reader.highlightRange == NSRange(location: 13, length: 7))
        reader.findPrevious()
        #expect(reader.highlightRange == NSRange(location: 3, length: 7))
        reader.findFromBeginning()
        #expect(reader.highlightRange == NSRange(location: 3, length: 7))
        reader.cancelPendingRead()
    }

    @Test func nativeReaderKeepsUnicodeSelectableAndCopiesToAnIsolatedPasteboard() async throws {
        let source = "🦉 A\tB\nGénesis 1:1"
        let mainClipboardChanges = NSPasteboard.general.changeCount
        let view = ReaderTextView(text: source, fontSize: 18, fontFamily: "serif",
            highlightRange: NSRange(location: 7, length: 7))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let native = try #require(descendantTextView(hosting))
        #expect(native.isSelectable)
        #expect(!native.isEditable)
        #expect(native.string == source)
        #expect(native.selectedRange() == NSRange(location: 7, length: 7))
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        native.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        #expect(native.writeSelection(to: clipboard, types: native.writablePasteboardTypes))
        #expect(clipboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")) == source)
        #expect(NSPasteboard.general.changeCount == mainClipboardChanges)
    }

    @Test func nativeInlineImageKeepsUTF16CoordinatesAndFitsTheReaderWidth() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 500, pixelsHigh: 250,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.setFillColor(NSColor.systemBlue.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 500, height: 250))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let source = "😀 \u{fffc} text"
        let graphic = ReaderGraphic(offset: 3, data: data, sha256: "own-test-image")
        let view = ReaderTextView(text: source, fontSize: 18, fontFamily: "serif", highlightRange: NSRange(location: 5, length: 4), graphics: [graphic])
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let native = try #require(descendantTextView(hosting) as? AttachmentReaderTextView)
        native.resizeInlineImages(force: true)
        let attachment = try #require(native.textStorage?.attribute(.attachment, at: 3, effectiveRange: nil) as? NSTextAttachment)
        #expect(native.string == source && (native.string as NSString).length == 9)
        #expect(native.selectedRange() == NSRange(location: 5, length: 4))
        #expect(attachment.image != nil)
        #expect(attachment.bounds.width <= native.bounds.width - 2 * native.textContainerInset.width)
        #expect(abs(attachment.bounds.height / attachment.bounds.width - 0.5) < 0.001)
        #expect(native.textStorage?.attribute(.attachment, at: 5, effectiveRange: nil) == nil)
    }

    @Test func nativeTableKeepsCellsOnTheSameRowWithoutChangingTextSelectionOrCopy() async throws {
        let source = "😀A\nB\n\nTail", table = readerTable(["😀A", "B"])
        let clipboardChanges = NSPasteboard.general.changeCount
        let hosting = NSHostingView(rootView: ReaderTextView(text: source, fontSize: 18, fontFamily: "serif",
            highlightRange: NSRange(location: 4, length: 1), tables: [table]))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let native = try #require(descendantTextView(hosting)), storage = try #require(native.textStorage)
        #expect(native.string == source && native.selectedRange() == NSRange(location: 4, length: 1))
        let firstStyle = try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let secondStyle = try #require(storage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle)
        let firstBlock = try #require(firstStyle.textBlocks.first as? NSTextTableBlock)
        let secondBlock = try #require(secondStyle.textBlocks.first as? NSTextTableBlock)
        #expect(firstBlock.table === secondBlock.table && firstBlock.table.numberOfColumns == 2)
        #expect(firstBlock.startingRow == 0 && secondBlock.startingRow == 0)
        #expect(firstBlock.startingColumn == 0 && secondBlock.startingColumn == 1)
        let tailStyle = try #require(storage.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)
        #expect(tailStyle.textBlocks.isEmpty)
        let layout = try #require(native.layoutManager), container = try #require(native.textContainer)
        layout.ensureLayout(for: container)
        let first = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 2), actualCharacterRange: nil), in: container)
        let second = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: 4, length: 1), actualCharacterRange: nil), in: container)
        #expect(second.minX > first.minX && abs(second.minY - first.minY) < 1)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        native.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        #expect(native.writeSelection(to: clipboard, types: native.writablePasteboardTypes))
        #expect(clipboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")) == source)
        #expect(NSPasteboard.general.changeCount == clipboardChanges)
    }

    @Test func anImageInsideATableCellFitsItsColumnAndKeepsItsObjectCoordinate() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 500, pixelsHigh: 250,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let source = "\u{fffc}\nRight\n\n", table = readerTable(["\u{fffc}", "Right"])
        let hosting = NSHostingView(rootView: ReaderTextView(text: source, fontSize: 18, fontFamily: "serif",
            highlightRange: NSRange(location: 2, length: 5), graphics: [.init(offset: 0, data: data, sha256: "own-cell-image")], tables: [table]))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 360)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let native = try #require(descendantTextView(hosting) as? AttachmentReaderTextView)
        native.resizeInlineImages(force: true)
        let attachment = try #require(native.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(native.string == source && native.selectedRange() == NSRange(location: 2, length: 5))
        #expect(attachment.bounds.width <= (native.bounds.width - 2 * native.textContainerInset.width) / 2)
        #expect(abs(attachment.bounds.height / attachment.bounds.width - 0.5) < 0.001)
    }

    private func readerTable(_ values: [String]) -> LegacyTable {
        var offset = 0
        let cells = values.map { text in
            let start = offset, count = text.utf16.count + 1
            offset += count
            let paragraph = LegacyParagraph(text: text, styleIdentifier: 0, flags: 0, characterOffset: start,
                declaredCharacterCount: UInt32(count), kind: .text, version: 1, declaredRunCount: 1, fieldAfterFlags: 0,
                fieldAfterCount: 0, decodedOffset: 0, label: nil, table: nil, children: [], containerVersion: nil)
            return LegacyTableCell(version: 1, versionFlags: 0, sourceFlags: 0, firstField: 0, secondField: 0,
                extendedField: nil, firstValue: 0, secondValue: 0, measurements: [], content: paragraph,
                characterOffset: start, characterCount: count, decodedOffset: 0)
        }
        let row = LegacyTableRow(version: 1, flags: 0, fields: [], measurements: [], cells: cells,
            characterOffset: 0, characterCount: offset, decodedOffset: 0)
        return LegacyTable(version: 1, sourceField: 0, overwrittenColumnField: 0, columnCount: UInt16(values.count),
            rows: [row], characterOffset: 0, characterCount: offset + 1, decodedOffset: 0)
    }

    private func settle(_ reader: ResourceReaderModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isLoading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(!reader.isLoading, "A bounded synthetic read did not finish within five seconds")
    }

    private func descendantTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let found = descendantTextView(child) { return found } }
        return nil
    }
}

/// Original synthetic LSFF framing and UTF-16 text. No installed library,
/// licensed book, network service, or user-selected path is a fixture dependency.
private struct ReaderFixture {
    let root: URL
    let resources: [LibraryResource]

    init(documents: [[String?]]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("libronx-ui-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values: [LibraryResource] = []
        for (index, sections) in documents.enumerated() {
            var tart = Data()
            for text in sections {
                var payload = Self.article(text ?? "Unsupported synthetic article")
                if text == nil { payload[20] = 2 }
                tart.append(Self.le16(0) + Self.le32(UInt32(payload.count)) + payload)
            }
            let data = Self.container(tart)
            let url = root.appendingPathComponent("synthetic-\(index + 1).LSF")
            try data.write(to: url)
            values.append(LibraryResource(location: url, title: "Synthetic \(index + 1)", byteCount: Int64(data.count),
                format: .legacyLSF, support: .metadataOnly, provenance: .fileName))
        }
        resources = values
    }

    func positionKey(_ index: Int) -> String { "readerPosition.v1." + resources[index].id }
    func remove() {
        for resource in resources {
            UserDefaults.standard.removeObject(forKey: "readerPosition.v1." + resource.id)
            UserDefaults.standard.removeObject(forKey: "readerBookmarks.v1." + resource.id)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func article(_ text: String) -> Data {
        let units = Array(text.utf16)
        var payload = Data(repeating: 0, count: 36)
        put16(17, in: &payload, at: 4)
        put32(1, in: &payload, at: 6)
        put16(1, in: &payload, at: 10)
        put16(1, in: &payload, at: 12)
        put32(UInt32(units.count), in: &payload, at: 16)
        put16(1, in: &payload, at: 20)
        put16(1, in: &payload, at: 22)
        put16(1, in: &payload, at: 24)
        put32(10_000, in: &payload, at: 26)
        put32(UInt32(units.count + 1), in: &payload, at: 32)
        payload.append(le16(17) + le16(0) + le16(0) + le16(UInt16(units.count)) + le16(1033) + Data([0xf0]))
        for unit in units { payload.append(le16(unit)) }
        payload.append(le16(0))
        put32(UInt32(payload.count), in: &payload, at: 0)
        return payload
    }

    private static func container(_ tart: Data) -> Data {
        var data = Data(repeating: 0, count: 88)
        data.replaceSubrange(0..<4, with: Data("LSFF".utf8))
        data.replaceSubrange(8..<12, with: Data("GTTL".utf8))
        data.replaceSubrange(36..<40, with: Data("pcr ".utf8))
        put32(36, in: &data, at: 40)
        data.replaceSubrange(44..<48, with: Data("LSFF".utf8))
        data.replaceSubrange(48..<52, with: Data("GTTL".utf8))
        data.replaceSubrange(62..<66, with: Data("tart".utf8))
        put32(UInt32(tart.count), in: &data, at: 70)
        put32(88, in: &data, at: 74)
        data.replaceSubrange(80..<84, with: Data("tart".utf8))
        put32(UInt32(tart.count), in: &data, at: 84)
        data.append(tart)
        put32(UInt32(data.count - 8), in: &data, at: 4)
        return data
    }
    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> (8 * $0)) & 255) }) }
    private static func put16(_ value: UInt16, in data: inout Data, at offset: Int) { data.replaceSubrange(offset..<(offset + 2), with: le16(value)) }
    private static func put32(_ value: UInt32, in data: inout Data, at offset: Int) { data.replaceSubrange(offset..<(offset + 4), with: le32(value)) }
}
