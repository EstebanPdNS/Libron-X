import AppKit
import CryptoKit
import Foundation
import Testing
import LibronixCore
@testable import MacRebuild

@MainActor struct ImportFormattingTests {
    @Test func legacyRepairsPreserveRealGreekHebrewAttributesAndAnchors() throws {
        let original = "Tםtulo: Jesתs · Versiףn · Bibliogrבficos · mσdulo estα · λόγος · אֱלֹהִים · σῶμα"
        let source = NSAttributedString(string: original, attributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.black])
        let repaired = ImportedTypography.normalize(source, repairCharacters: true)
        #expect(repaired.text.string == "Título: Jesús · Versión · Bibliográficos · módulo está · λόγος · אֱלֹהִים · σῶμα")
        #expect(repaired.text.length == source.length && repaired.repairs == 6)
        let font = try #require(repaired.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(ImportedTypography.normalize(source).text.string == original)
    }
    @Test func htmlSanitizationRetainsRichStructureAndRemovesExternalLoads() throws {
        let source = "<style>.title { font-weight:bold }</style><p dir='rtl'><b>Amor 😀</b> <i>λόγος</i></p><table><tr><td>Uno</td><td>Dos</td></tr></table><ul><li>Vida</li></ul><script>bad()</script><img src='https://invalid.test/x'><span onclick='bad()' style='background:url(https://invalid.test/y)'>Fin</span>"
        let html = ImportFormattingPipeline.html(source)
        #expect(html.html.contains("<table>") && html.html.contains("<ul>") && html.html.contains("dir='rtl'") && html.html.contains("font-weight:bold"))
        #expect(!html.html.contains("bad()") && !html.html.contains("invalid.test"))
        let page = try ESwordReader.project(.init(ordinal: 0, entries: [.init(title: "test", body: source, reference: nil)], contents: ["test"]), request: .init(ordinal: 0))
        for word in ["Amor 😀", "λόγος", "Uno", "Dos", "Vida", "Fin"] { #expect(page.text.contains(word)) }
        #expect(page.content?.plainText == page.text)
        #expect(page.content?.richTextRTF != nil)
    }
    @Test func neutralTextAdaptsToBothAppearancesAndZoomScalesParagraphs() throws {
        let paragraph = NSMutableParagraphStyle(); paragraph.headIndent = 20; paragraph.paragraphSpacing = 8
        let text = NSAttributedString(string: "Legible", attributes: [.foregroundColor: NSColor.black, .backgroundColor: NSColor.white, .paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 12)])
        let normalized = ImportedTypography.normalize(text).text
        #expect(normalized.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        let color = try #require(normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        var levels: [CGFloat] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance { levels.append(color.usingColorSpace(.sRGB)!.redComponent) }
        }
        #expect(levels[0] < 0.2 && levels[1] > 0.8)
        ImportedTypography.scaleParagraphs(normalized, scale: 2)
        let scaled = try #require(normalized.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(scaled.headIndent == 40 && scaled.paragraphSpacing == 16)
    }
    @Test func suppliedDJNEveryArticleProjectsWithoutChangingOriginalBytes() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRONX_DJN_RESOURCE"] else { return }
        let url = URL(fileURLWithPath: path)
        let before = SHA256.hash(data: try Data(contentsOf: url))
        let audit = try ESwordResource.audit(url)
        #expect(audit.entries == 807 && audit.emptyEntries == 0)
        for ordinal in 0..<audit.entries {
            let source = try ESwordResource.page(url, ordinal: ordinal)
            let projected = try ESwordReader.project(source, request: .init(ordinal: ordinal))
            #expect(!projected.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty projected article \(ordinal)")
            let rendered = ReaderTypography.render(text: projected.text, content: projected.content, typography: nil).text
            #expect(rendered.string == projected.text)
        }
        let after = SHA256.hash(data: try Data(contentsOf: url))
        #expect(Array(before) == Array(after))
    }
}
