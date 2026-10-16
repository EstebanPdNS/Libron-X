import AppKit
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ReaderInterlinearCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_PENDING_FORMAT_CORPUS"] != nil))
    func actualGreekAndHebrewUnitsKeepSourceCoordinatesAndReserveMultilineBoxes() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_PENDING_FORMAT_CORPUS"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_PENDING_FORMAT_RECEIPT"]))
        for (name, ordinal, lineCount) in [("RVR60NTRI.lbxlls", 153, 7), ("RVR60OTRI.lbxlls", 493, 4)] {
            let url = directory.appendingPathComponent(name), archive = try LibronixBookArchive.inspect(at: url)
            let metadata = try archive.metadata(), before = try LegacyGraphicsService.fileStamp(url)
            let resource = LibraryResource(location: url, title: metadata.title ?? name, byteCount: Int64(before.size),
                format: .libronixLLS, support: .metadataOnly, provenance: .libronixMetadata, legacyIdentifier: metadata.identifier)
            let page = try await ReaderSession.read(resource, .init(ordinal: ordinal)), content = try #require(page.content)
            let units = try #require(content.interlinears)
            #expect(!units.isEmpty && page.interlinearLines.count == lineCount)
            #expect(units.allSatisfy { $0.lines.count == lineCount })
            let visible = Set(page.interlinearLines.filter(\.visibleByDefault).map(\.ordinal))
            let display = ReaderTypography.render(text: page.text, content: content, typography: page.typography,
                                                  visibleInterlinearLines: visible)
            #expect(display.text.string == page.text)
            let view = ReaderOutputActions.printView(display.text, info: NSPrintInfo.shared)
            let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
            layout.ensureLayout(for: container)
            let first = units[0], position = first.surfaceCharacterOffset
            let unit = try #require(display.text.attribute(.readerInterlinearUnit, at: position, effectiveRange: nil) as? ReaderInterlinearGlyph)
            let glyph = layout.glyphIndexForCharacter(at: position)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            print("Interlinear box \(name): rows=\(unit.rows.count), expected=\(unit.size), actual=\(rect), pageHeight=\(view.bounds.height), warnings=\(display.warnings)")
            #expect(unit.rows.count == visible.count)
            #expect(rect.width >= unit.size.width - 1)
            #expect(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height >= unit.size.height - 1)
            #expect(view.bounds.height > 1500)
            let pdf = view.dataWithPDF(inside: NSRect(x: 0, y: 0, width: view.bounds.width, height: min(800, view.bounds.height)))
            try pdf.write(to: output.appendingPathComponent(name + ".layout.pdf"))
            if let image = NSImage(data: pdf), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent(name + ".layout.png"))
            }
            let surfaceOnly = ReaderTypography.render(text: page.text, content: content, typography: page.typography, visibleInterlinearLines: [0])
            let one = try #require(surfaceOnly.text.attribute(.readerInterlinearUnit, at: position, effectiveRange: nil) as? ReaderInterlinearGlyph)
            #expect(one.rows.count == 1 && one.size.height < unit.size.height)
            #expect(surfaceOnly.text.string == display.text.string && surfaceOnly.text.length == display.text.length)
            #expect(try LegacyGraphicsService.fileStamp(url) == before)
        }
    }
}
