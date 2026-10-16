import AppKit
import Testing
@testable import LibronixCore
@testable import MacRebuild

@MainActor struct ReaderPresentationTests {
    private func font(height: UInt32 = 240, weight: UInt32 = 400, italic: Bool = false, underline: Bool = false, strikeout: Bool = false) -> LegacyFontDescription {
        .init(values: [height, 0, 0, 0, weight], attributes: [italic ? 1 : 0, underline ? 1 : 0, strikeout ? 1 : 0, 0, 0, 0, 0, 0], family: "Times New Roman", rawFamily: Data())
    }
    private func style(flags: UInt32 = 0, font: LegacyFontDescription? = nil, alternate: LegacyFontDescription? = nil) -> LegacyCharacterStyle {
        .init(id: 0, version: 1, flags: flags, color: 0x332211, backgroundColor: nil, locale: 1034,
              sourceField: 0, extraField: nil, extraValue: nil, font: font ?? self.font(), alternateFont: alternate)
    }
    private func typography(_ styles: [LegacyCharacterStyle]) -> LegacyTypography {
        .init(version: 1, fontGroupVersion: 1, fontGroups: [], characterStyles: styles, paragraphStyles: [], opaqueTail: Data())
    }
    @Test func decodedUnicodeRunUsesTheSourceStyleAndPreservesEveryUTF16Position() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Árbol α 😀 texto"]]); defer { fixture.remove() }
        let content = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        let styles = typography([style(flags: 0x40, font: font(height: 320, weight: 700, italic: true, underline: true, strikeout: true))])
        let result = ReaderTypography.render(text: content.plainText, content: content, typography: styles)
        #expect(result.text.string == content.plainText && result.text.length == content.plainText.utf16.count)
        let attributes = result.text.attributes(at: 0, effectiveRange: nil)
        let font = try #require(attributes[.font] as? NSFont)
        #expect(font.pointSize == 16)
        let traits = NSFontManager.shared.traits(of: font)
        #expect(traits.contains(.boldFontMask) && traits.contains(.italicFontMask))
        #expect(attributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attributes[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        let color = try #require((attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 17.0 / 255) < 0.001)
        #expect(abs(color.greenComponent - 34.0 / 255) < 0.001)
        #expect(abs(color.blueComponent - 51.0 / 255) < 0.001)
    }
    @Test func superscriptUsesTheStoredAlternateFontAndScaleKeepsBaselineProportional() throws {
        var warnings = Set<String>()
        let source = style(flags: 1, alternate: font(height: 168))
        let attributes = ReaderTypography.characterAttributes(source, typography: typography([source]), scale: 1.5, warnings: &warnings)
        #expect(abs(((attributes[.font] as? NSFont)?.pointSize ?? 0) - 12.6) < 0.001)
        #expect(abs((attributes[.baselineOffset] as? Double ?? 0) - 5.94) < 0.001)
        let sub = style(flags: 2)
        let lower = ReaderTypography.characterAttributes(sub, typography: typography([sub]), scale: 1, warnings: &warnings)
        #expect((lower[.baselineOffset] as? Double ?? 0) < 0)
    }
    @Test func paragraphIndentationAlignmentDirectionAndSpacingUseTwips() {
        let source = LegacyParagraphStyle(version: 3, borders: [], firstValue: 0, secondValue: 0,
            fields: [1, 0, 400, 200, UInt16(bitPattern: -100), 120, 240, 0, 0, 0], name: "Authored",
            extraLineHeight: -360, flags: 0x12, tabStops: [.init(version: 1, kind: 0, position: 720)])
        let rendered = ReaderTypography.paragraphStyle(source, scale: 1.5)
        #expect(rendered.alignment == .center && rendered.baseWritingDirection == .rightToLeft)
        #expect(rendered.headIndent == 30 && rendered.firstLineHeadIndent == 22.5 && rendered.tailIndent == -15)
        #expect(rendered.paragraphSpacingBefore == 9 && rendered.paragraphSpacing == 18)
        #expect(rendered.minimumLineHeight == 27 && rendered.maximumLineHeight == 27)
        #expect(rendered.tabStops.first?.location == 54)
    }
    @Test func mismatchedSourceCannotApplyStylesToAnotherArticle() throws {
        let fixture = try AuthoredReaderFixture(documents: [["Source"]]); defer { fixture.remove() }
        let content = try LegacyContentReader.readSection(lsfURL: fixture.resources[0].location, ordinal: 0)
        let rendered = ReaderTypography.render(text: "Another 😀 article", content: content, typography: typography([style()]))
        #expect(rendered.text.string == "Another 😀 article" && rendered.warnings.count == 1)
    }
    private func asset(offset: Int = 3, data: Data) -> LegacyGraphicAsset {
        .init(graphic: .init(sourceRunFlags: 0, attribute: nil, reference: "!authored.png", characterOffset: offset,
                            decodedOffset: 0, fileOffset: nil, rawHeaderHex: ""), name: "authored.png", data: data, sha256: "authored")
    }
    private func authoredImage() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    @Test func mapAttachmentReplacesExactlyTheSourceObjectAndResizesWithoutChangingAspectOrText() throws {
        let source = "😀 \u{fffc}\nAfter"
        let display = NSMutableAttributedString(string: source)
        let rendered = ReaderImageRenderer.install([asset(data: try authoredImage())], in: display)
        #expect(rendered.images.count == 1 && rendered.warnings.isEmpty)
        #expect(display.string == source && display.length == source.utf16.count)
        #expect(display.attribute(.attachment, at: 3, effectiveRange: nil) is NSTextAttachment)
        #expect(display.attribute(.attachment, at: 2, effectiveRange: nil) == nil)
        let view = ActiveTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.textStorage?.setAttributedString(display); view.inlineImages = rendered.images; view.fitImages()
        let item = try #require(rendered.images.first)
        #expect(abs(item.attachment.bounds.width / item.attachment.bounds.height - 2) < 0.001)
        #expect(item.attachment.bounds.width <= 200 && item.attachment.bounds.width > 0)
        view.setFrameSize(NSSize(width: 800, height: 300))
        #expect(item.attachment.bounds.size == item.originalSize)
        #expect(view.string == source)
        var opened = ""
        view.onOpenImage = { _, name in opened = name }
        let delegate: any NSTextViewDelegate = ReaderTextView.Coordinator()
        let cell = try #require(item.attachment.attachmentCell)
        delegate.textView?(view, doubleClickedOn: cell, in: item.attachment.bounds, at: 3)
        #expect(opened == "authored.png")
        #expect(!view.openImage(at: 2))
    }
    @Test func brokenAndMispositionedImagesAreReportedWithoutReplacingSourceText() throws {
        let display = NSMutableAttributedString(string: "A\u{fffc}Z")
        let rendered = ReaderImageRenderer.install([asset(offset: 1, data: Data([0, 1, 2])), asset(offset: 0, data: try authoredImage())], in: display)
        #expect(rendered.images.isEmpty && rendered.warnings.count == 2)
        #expect(display.string == "A\u{fffc}Z")
    }
}

@MainActor struct LocalMapCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_MAP_CORPUS"] != nil))
    func rvr95GraphicCorpusDecodesAndPreservesSourcePositions() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_MAP_CORPUS"]))
        let url = directory.appendingPathComponent("RVR95.LSF")
        let before = try LegacyGraphicsService.fileStamp(url)
        let index = try LegacyContentReader.inspectSections(lsfURL: url)
        let service = LegacyGraphicsService()
        var articles = 0, declared = 0, loaded = 0, failures: [String] = [], warnings: [String] = []
        var receipts: [[String: String]] = []
        for section in index.sections {
            let content: LegacySectionContent
            do { content = try LegacyContentReader.readSection(lsfURL: url, descriptor: section, tartEnd: index.tartOffset + index.tartLength) }
            catch { failures.append("\(section.ordinal): \(error.localizedDescription)"); continue }
            guard !content.graphics.isEmpty else { continue }
            articles += 1; declared += content.graphics.count
            let result = try await service.load(url, graphics: content.graphics, expectedSource: before)
            warnings += result.warnings
            let display = NSMutableAttributedString(string: content.plainText)
            let installed = ReaderImageRenderer.install(result.assets, in: display)
            loaded += installed.images.count; warnings += installed.warnings
            #expect(display.string == content.plainText)
            receipts += result.assets.map { ["ordinal": String(section.ordinal), "name": $0.name, "sha256": $0.sha256] }
        }
        #expect(failures.isEmpty)
        #expect(declared > 0 && loaded == declared)
        #expect(try LegacyGraphicsService.fileStamp(url) == before)
        print("RVR95 graphic corpus: sections=\(index.sections.count), imageArticles=\(articles), declared=\(declared), installed=\(loaded), unreadable=\(failures.count), warnings=\(warnings.count)")
        if let output = ProcessInfo.processInfo.environment["LIBRONX_MAP_RECEIPT"] {
            let receipt: [String: Any] = ["resource": "RVR95.LSF", "sections": index.sections.count,
                "imageArticles": articles, "declaredImages": declared, "installedImages": loaded,
                "unreadableArticles": failures, "warnings": warnings, "assets": receipts, "sourceStampPreserved": true]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBRONX_MAP_CORPUS"] != nil))
    func rvr95RomanEmpireArticleLoadsItsActualMapBytesAndNativeAttachment() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBRONX_MAP_CORPUS"]))
        let url = directory.appendingPathComponent("RVR95.LSF")
        let before = try LegacyGraphicsService.fileStamp(url)
        let sections = try LegacyContentReader.inspectSections(lsfURL: url)
        var targetOrdinal: Int?
        for section in sections.sections {
            guard section.decodedLength <= 16_384 else { continue }
            guard let content = try? LegacyContentReader.readSection(lsfURL: url, descriptor: section, tartEnd: sections.tartOffset + sections.tartLength) else { continue }
            if content.plainText.localizedStandardContains("Imperio romano en tiempos de Cristo") {
                targetOrdinal = section.ordinal; break
            }
        }
        let target = try #require(targetOrdinal)
        let resource = LibraryResource(location: url, title: "Reina Valera 1995", byteCount: Int64(before.size), format: .legacyLSF,
                                       support: .metadataOnly, provenance: .legacyPublicMetadata)
        let page = try await ReaderSession.read(resource, .init(ordinal: target))
        #expect(!page.graphics.isEmpty)
        let display = NSMutableAttributedString(attributedString: ReaderTypography.render(text: page.text, content: page.content, typography: page.typography).text)
        let installed = ReaderImageRenderer.install(page.graphics, in: display)
        #expect(installed.images.count == page.graphics.count && installed.warnings.isEmpty)
        #expect(display.string == page.text)
        #expect(try LegacyGraphicsService.fileStamp(url) == before)
        print("RVR95 verified map ordinal=\(target) assets=\(page.graphics.map { "\($0.name):\($0.sha256)" })")
    }
}
