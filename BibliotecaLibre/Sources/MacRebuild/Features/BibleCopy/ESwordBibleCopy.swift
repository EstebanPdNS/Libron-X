import AppKit
import Foundation
import LibronixCore

/// Projects checked SQLite verse rows into the existing copy formatter. Each
/// row has its own source coordinates, independent of the reader's chapter.
@MainActor enum ESwordBibleCopy {
    static func prepare(_ selection: ESwordBiblePassage, abbreviation: String) async throws -> BibleCopyDocument {
        var verses: [BibleCopyVerse] = []
        var paragraphs: [BibleCopySourceParagraph] = []
        var sources: [ReaderOutputSource] = []
        var total = 0
        for row in selection.verses {
            await Task.yield()
            try Task.checkCancellation()
            let raw = row.encodedBody
            let value: NSAttributedString
            if raw.hasPrefix("{\\rtf") {
                guard !raw.localizedCaseInsensitiveContains("\\footnote"), !raw.localizedCaseInsensitiveContains("\\object"), !raw.localizedCaseInsensitiveContains("\\pict") else { throw BibleCopyError.unsupportedContent }
                value = try NSAttributedString(data: Data(raw.utf8), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            } else if raw.contains("<") || raw.contains("&") {
                let html = ImportFormattingPipeline.html(raw)
                guard html.removedActiveSurfaces == 0,
                      raw.range(of: #"<\s*(table|ul|ol)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { throw BibleCopyError.unsupportedContent }
                value = try NSAttributedString(data: Data(html.html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            } else { value = NSAttributedString(string: raw) }
            let text = ImportFormattingPipeline.repairLegacyCharacters(value.string).text
            total += text.utf16.count
            guard total <= 4_000_000, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0") else { throw BibleCopyError.incompleteSource }
            let source = ReaderOutputSource(sectionOrdinal: row.sectionOrdinal, decodedTextSHA256: LibrarySearchService.textFingerprint(text), selectedRange: .init(location: 0, length: text.utf16.count), verseReference: row.reference)
            var fragments: [BibleCopyFragment] = []
            var index = 0
            let nsText = text as NSString
            while index < value.length {
                var effective = NSRange()
                let attrs = value.attributes(at: index, effectiveRange: &effective)
                guard attrs[.attachment] == nil, attrs[.link] == nil else { throw BibleCopyError.unsupportedContent }
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let foreground = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
                let color: UInt32? = foreground.flatMap { c in
                    guard c != NSColor.textColor.usingColorSpace(.sRGB) else { return nil }
                    let red = UInt32((min(1, max(0, c.redComponent)) * 255).rounded())
                    let green = UInt32((min(1, max(0, c.greenComponent)) * 255).rounded())
                    let blue = UInt32((min(1, max(0, c.blueComponent)) * 255).rounded())
                    return red | green << 8 | blue << 16
                }
                let superscript = (attrs[.superscript] as? NSNumber)?.intValue ?? 0
                let style = LegacyCharacterStyle.importedOutput(bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask), underline: (attrs[.underlineStyle] as? NSNumber)?.intValue != nil && (attrs[.underlineStyle] as? NSNumber)?.intValue != 0, strikeout: (attrs[.strikethroughStyle] as? NSNumber)?.intValue != nil && (attrs[.strikethroughStyle] as? NSNumber)?.intValue != 0, superscript: superscript > 0, subscriptText: superscript < 0, color: color)
                let range = NSRange(location: index, length: min(effective.length, value.length - index))
                fragments.append(.init(text: nsText.substring(with: range), style: style, sourceRange: .init(location: range.location, length: range.length), footnote: nil, isBibleText: true, isVerseNumber: false))
                index = NSMaxRange(range)
            }
            let verse = BibleCopyVerse(address: row.address, sourceReference: row.reference, source: source, paragraphKey: row.reference, paragraphStyle: nil, fragments: fragments)
            verses.append(verse); sources.append(source)
            // Preserve paragraph breaks in the source while retaining the
            // attribute ranges and the verse marker's row-local offset.
            var position = 0
            while position < nsText.length {
                let line = nsText.paragraphRange(for: NSRange(location: position, length: 0))
                let end = NSMaxRange(line)
                var contentEnd = end
                while contentEnd > line.location, let scalar = Unicode.Scalar(nsText.character(at: contentEnd - 1)), CharacterSet.newlines.contains(scalar) { contentEnd -= 1 }
                var parts: [BibleCopyFragment] = []
                for fragment in fragments {
                    let start = max(line.location, fragment.sourceRange.location)
                    let stop = min(contentEnd, fragment.sourceRange.upperBound)
                    if start < stop {
                        parts.append(.init(text: nsText.substring(with: NSRange(location: start, length: stop-start)), style: fragment.style, sourceRange: .init(location: start, length: stop-start), footnote: nil, isBibleText: true, isVerseNumber: false))
                    }
                }
                paragraphs.append(.init(style: nil, fragments: parts, marks: position == 0 ? [.init(offset: 0, address: row.address)] : []))
                position = end
            }
        }
        try selection.verifyUnchanged()
        let resource = selection.resource
        let report = try BibliographyReportGenerator.generate(resources: [resource], scope: .init(kind: .selection, names: [], requestedCount: 1))
        return BibleCopyDocument(resourceID: resource.id, passage: selection.passage, title: resource.title, abbreviation: abbreviation, verses: verses, footnotes: [], citation: ResourceCitation.text(report.entries[0], style: .catalog), sources: sources, fullParagraphs: [], sourceLanguages: resource.languages, sourceParagraphs: paragraphs)
    }
}
