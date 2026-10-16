import AppKit
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ReaderFormattingCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_FORMAT_CORPUS"] != nil))
    func sourceStylesAndNativeRenderingPreserveAllSampledResourceCoordinates() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_FORMAT_CORPUS"]))
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "lsf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records: [[String: Any]] = []
        for url in urls {
            let stamp = try LegacyGraphicsService.fileStamp(url)
            let typography = try LegacyTypographyReader.inspect(lsfURL: url)
            let sections = try LegacyContentReader.inspectSections(lsfURL: url)
            let ordinals = Set(Array(0..<min(8, sections.sections.count)) + [sections.sections.count / 2, max(0, sections.sections.count - 1)] + (url.lastPathComponent == "GUIAGRK.LSF" ? [140] : []) + (url.lastPathComponent == "RVR95.LSF" ? [8, 19437] : []))
            var samples: [[String: Any]] = []
            for ordinal in ordinals.sorted() {
                guard sections.sections.indices.contains(ordinal) else { continue }
                let content: LegacySectionContent
                do { content = try LegacyContentReader.readSection(lsfURL: url, descriptor: sections.sections[ordinal], tartEnd: sections.tartOffset + sections.tartLength) }
                catch { samples.append(["ordinal": ordinal, "decodeError": error.localizedDescription]); continue }
                let display = ReaderTypography.render(text: content.plainText, content: content, typography: typography)
                #expect(display.text.string == content.plainText)
                #expect(display.text.length == content.plainText.utf16.count)
                var fonts = Set<String>(), paragraphSpans = 0, tableSpans = 0
                display.text.enumerateAttributes(in: NSRange(location: 0, length: display.text.length)) { attributes, _, _ in
                    if let font = attributes[.font] as? NSFont { fonts.insert("\(font.fontName):\(font.pointSize)") }
                    if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
                        paragraphSpans += 1
                        if !paragraph.textBlocks.isEmpty { tableSpans += 1 }
                    }
                }
                samples.append(["ordinal": ordinal, "utf16": content.plainText.utf16.count,
                    "fonts": fonts.sorted(), "paragraphAttributeSpans": paragraphSpans, "tableAttributeSpans": tableSpans,
                    "sourceParagraphs": content.paragraphs.count, "tables": content.tables.count,
                    "runStyleIDs": Array(Set(content.runs.map(\.styleIdentifier))).sorted(),
                    "paragraphStyleIDs": Array(Set(content.paragraphs.map(\.styleIdentifier))).sorted(),
                    "warnings": display.warnings])
                if url.lastPathComponent == "GUIAGRK.LSF", ordinal == 140,
                   let output = ProcessInfo.processInfo.environment["LIBRONX_FORMAT_RECEIPT"] {
                    try JSONEncoder().encode(content).write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("guiagrk-table-source.json"))
                    let view = ReaderOutputActions.printView(display.text, info: NSPrintInfo.shared)
                    let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
                    let row = try #require(content.tables.first?.rows.first { $0.cells.first?.content.text == "Gamma" })
                    let name = row.cells[0].characterOffset, greek = row.cells[1].characterOffset
                    layout.ensureLayout(for: container)
                    func glyphRect(_ character: Int) -> NSRect {
                        layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil), in: container)
                    }
                    let nameRect = glyphRect(name), greekRect = glyphRect(greek)
                    #expect(greekRect.minX > nameRect.maxX)
                    #expect(abs(greekRect.minY - nameRect.minY) < 8)
                    #expect((view.string as NSString).substring(with: NSRange(location: 174, length: 5)) == "Gamma")
                    let image = view.dataWithPDF(inside: NSRect(x: 0, y: 0, width: view.bounds.width, height: min(1000, view.bounds.height)))
                    try image.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("guiagrk-layout.pdf"))
                }
            }
            #expect(try LegacyGraphicsService.fileStamp(url) == stamp)
            records.append(["resource": url.lastPathComponent, "characterStyles": typography.characterStyles.count,
                "paragraphStyles": typography.paragraphStyles.count, "samples": samples, "sourceStampPreserved": true])
        }
        #expect(!records.isEmpty)
        if let output = ProcessInfo.processInfo.environment["LIBRONX_FORMAT_RECEIPT"] {
            try JSONSerialization.data(withJSONObject: ["resources": records, "resourceCount": records.count], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
        print("Native formatting corpus: \(records.count) resources; all decoded sample UTF-16 positions preserved")
    }
}
