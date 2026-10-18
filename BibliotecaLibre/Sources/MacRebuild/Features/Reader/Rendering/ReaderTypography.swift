import AppKit
import CoreText
import LibronixCore

struct RenderedReaderText {
    let text: NSAttributedString
    let warnings: [String]
}

/// Maps decoded source styles onto an unchanged UTF-16 body. Layout objects
/// require separate rendering; applying styles must never move a source anchor.
@MainActor enum ReaderTypography {
    static func render(text: String, content: LegacySectionContent?, typography: LegacyTypography?, scale: Double = 1,
                       visibleInterlinearLines: Set<Int>? = nil, usesChosenFont: Bool = true) -> RenderedReaderText {
        let scale = scale.isFinite ? min(4.5, max(0.015, scale)) : 1
        let fallback = NSFont(name: (!usesChosenFont || AppPreferences.shared.readingFont.isEmpty) ? "Times New Roman" : AppPreferences.shared.readingFont, size: 12 * scale) ?? NSFont.systemFont(ofSize: 12 * scale)
        let result = NSMutableAttributedString(string: text, attributes: [.font: fallback, .foregroundColor: NSColor.textColor])
        func applyChosenFont(_ text: NSMutableAttributedString) {
            let family = AppPreferences.shared.readingFont
            guard usesChosenFont, !family.isEmpty else { return }
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                let original = value as? NSFont ?? fallback
                let chosen = NSFontManager.shared.convert(original, toFamily: family)
                text.addAttribute(.font, value: chosen, range: range)
            }
        }
        defer { applyChosenFont(result) }
        if let rtf = content?.richTextRTF,
           let imported = try? NSMutableAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           imported.string == text {
            let normalized = ImportedTypography.normalize(imported).text
            imported.setAttributedString(normalized)
            ImportedTypography.scaleParagraphs(imported, scale: scale)
            imported.enumerateAttribute(.font, in: NSRange(location: 0, length: imported.length)) { value, range, _ in
                if let font = value as? NSFont { imported.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * scale), range: range) }
            }
            applyChosenFont(imported)
            return .init(text: imported, warnings: [])
        }
        guard let content, let typography else { return .init(text: result, warnings: []) }
        guard content.plainText == text else {
            return .init(text: result, warnings: ["Los estilos no coinciden con el texto mostrado."])
        }
        var warnings = Set<String>()
        // Source articles repeat a small style set across hundreds of runs.
        // Font discovery belongs to the render, not to each word/run. This
        // cache is local so source-font registration can refresh a later render.
        var attributeCache: [UInt16: [NSAttributedString.Key: Any]] = [:]
        func attributes(for id: UInt16) -> [NSAttributedString.Key: Any]? {
            if let cached = attributeCache[id] { return cached }
            guard let style = typography.characterStyle(id) else { return nil }
            let value = characterAttributes(style, typography: typography, scale: scale, warnings: &warnings)
            attributeCache[id] = value
            return value
        }
        let source = text as NSString
        func range(_ location: Int, _ length: Int) -> NSRange? {
            guard location >= 0, length >= 0, location <= source.length, length <= source.length - location else { return nil }
            return NSRange(location: location, length: length)
        }
        func applyParagraph(_ paragraph: LegacyParagraph, blocks: [NSTextBlock] = []) {
            if let span = range(paragraph.characterOffset, paragraph.text.utf16.count),
               source.substring(with: span) == paragraph.text {
                var fullSpan = span
                if NSMaxRange(span) < source.length && source.character(at: NSMaxRange(span)) == 10 { fullSpan.length += 1 }
                let definition = typography.paragraphStyle(paragraph.styleIdentifier)
                let style = definition.map { paragraphStyle($0, scale: scale).mutableCopy() as! NSMutableParagraphStyle } ?? NSMutableParagraphStyle()
                style.textBlocks = blocks
                if let definition {
                    if let base = attributes(for: definition.characterStyleID) {
                        result.addAttributes(base, range: fullSpan)
                    }
                    if let border = ReaderTableLayout.borderBlock(definition.borders, scale: scale) { style.textBlocks.append(border) }
                } else { warnings.insert("El recurso contiene un estilo de párrafo sin resolver: \(paragraph.styleIdentifier).") }
                if let label = paragraph.label, !label.text.isEmpty, fullSpan.length > 0, paragraph.kind == .text {
                    let font = result.attribute(.font, at: span.location, effectiveRange: nil) as? NSFont ?? fallback
                    let width = (label.text as NSString).size(withAttributes: [.font: font]).width + font.pointSize * 0.35
                    style.headIndent = max(style.headIndent, width)
                    style.firstLineHeadIndent = max(style.firstLineHeadIndent, width)
                    result.addAttribute(.readerListLabel, value: label.text, range: NSRange(location: span.location, length: 1))
                }
                if fullSpan.length > 0 { result.addAttribute(.paragraphStyle, value: style, range: fullSpan) }
            } else {
                warnings.insert("Un párrafo quedó fuera de su intervalo de texto.")
            }
            for child in paragraph.children { applyParagraph(child, blocks: blocks) }
            if let table = paragraph.table {
                for cell in ReaderTableLayout.cells(table, scale: scale, warnings: &warnings) {
                    applyParagraph(cell.source.content, blocks: blocks + [cell.block])
                }
            }
        }
        for paragraph in content.paragraphs { applyParagraph(paragraph) }
        var wordStarts: [(Int, String)] = []
        if content.runs.contains(where: { typography.characterStyle($0.styleIdentifier)?.capitalizeWords == true }) {
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, start, _, _ in
                if let first = word?.first { wordStarts.append((NSRange(start, in: text).location, String(first))) }
            }
        }
        for run in content.runs {
            guard let span = range(run.characterOffset, run.logicalCharacterCount), span.length > 0,
                  source.substring(with: span) == run.logicalText else {
                if !run.logicalText.isEmpty { warnings.insert("Un estilo quedó fuera de su intervalo de texto.") }
                continue
            }
            guard let style = typography.characterStyle(run.styleIdentifier) else {
                warnings.insert("El recurso contiene un estilo de carácter sin resolver."); continue
            }
            if let attributes = attributes(for: run.styleIdentifier) { result.addAttributes(attributes, range: span) }
            if style.capitalizeWords {
                for (offset, first) in wordStarts where NSLocationInRange(offset, span) {
                    let upper = first.uppercased()
                    guard upper != first else { continue }
                    if first.utf16.count == 1, upper.utf16.count == 1, let code = upper.utf16.first {
                        result.addAttribute(.readerCapitalizedGlyph, value: NSNumber(value: code), range: NSRange(location: offset, length: 1))
                    } else { warnings.insert("La capitalización de algunos caracteres compuestos todavía requiere representación.") }
                }
            }
        }
        ReaderInterlinearLayout.apply(content.interlinears ?? [], to: result, typography: typography, scale: scale,
                                      visibleLines: visibleInterlinearLines, warnings: &warnings)
        return .init(text: result, warnings: warnings.sorted())
    }

    static func characterAttributes(_ style: LegacyCharacterStyle, typography: LegacyTypography, scale: Double,
                                    warnings: inout Set<String>) -> [NSAttributedString.Key: Any] {
        let script = style.isSuperscript || style.isSubscript
        let description = script ? style.alternateFont ?? style.font : style.font
        let rawSize = Double(description.height) / 20
        let points = rawSize > 0 && rawSize <= 144 ? rawSize : 12
        let manager = NSFontManager.shared
        let requestedFamily = typography.family(for: description)
        let family = manager.availableFontFamilies.first { $0.caseInsensitiveCompare(requestedFamily) == .orderedSame } ?? requestedFamily
        var traits: NSFontTraitMask = []
        if description.italic { traits.insert(.italicFontMask) }
        if description.weight > 400 { traits.insert(.boldFontMask) }
        let requestedFont = manager.font(withFamily: family, traits: traits, weight: description.weight > 400 ? 9 : 5, size: points * scale)
            ?? NSFont(name: family, size: points * scale)
        let font = requestedFont ?? NSFont(name: "Times New Roman", size: points * scale) ?? .systemFont(ofSize: points * scale)
        if requestedFont == nil { warnings.insert("Fuente sustituida en Mac: \(family)") }
        var renderedFont = manager.convert(font, toHaveTrait: traits)
        if style.smallCaps {
            let descriptor = renderedFont.fontDescriptor.addingAttributes([.featureSettings: [
                [NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType, NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector]
            ]])
            renderedFont = NSFont(descriptor: descriptor, size: points * scale) ?? renderedFont
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: renderedFont,
            .foregroundColor: style.flags & 0x40 != 0 ? color(style.color) : NSColor.textColor,
            .underlineStyle: description.underline ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: description.strikeout ? NSUnderlineStyle.single.rawValue : 0,
            .baselineOffset: 0.0
        ]
        if style.isSuperscript { attributes[.baselineOffset] = Double(style.font.height) / 20 * scale * 0.33 }
        else if style.isSubscript { attributes[.baselineOffset] = -Double(style.font.height) / 20 * scale * 0.20 }
        // The presence of a v2 background field does not prove it is enabled.
        // Retain it in source metadata until its activation flag is verified.
        if let background = style.backgroundColor, background != 0 { warnings.insert("El fondo del estilo todavía requiere validación.") }
        return attributes
    }

    static func paragraphStyle(_ source: LegacyParagraphStyle, scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch source.alignment {
        case .left: style.alignment = .left
        case .right: style.alignment = .right
        case .center: style.alignment = .center
        case .justified: style.alignment = .justified
        case nil: style.alignment = .natural
        }
        style.baseWritingDirection = source.rightToLeft ? .rightToLeft : .natural
        let factor = scale / 20
        style.headIndent = Double(source.headIndent) * factor
        style.firstLineHeadIndent = Double(Int(source.headIndent) + Int(source.firstLineIndent)) * factor
        style.tailIndent = -Double(source.tailIndent) * factor
        style.paragraphSpacingBefore = max(0, Double(source.spaceBefore) * factor)
        style.paragraphSpacing = max(0, Double(source.spaceAfter) * factor)
        if let height = source.extraLineHeight {
            if height < 0 { style.minimumLineHeight = Double(-Int(height)) * factor; style.maximumLineHeight = style.minimumLineHeight }
            else { style.lineSpacing = Double(height) * factor }
        }
        style.tabStops = source.tabStops.compactMap { tab in
            let alignment: NSTextAlignment
            switch tab.kind { case 0: alignment = .left; case 1: alignment = .center; case 2: alignment = .right; default: return nil }
            return NSTextTab(textAlignment: alignment, location: max(0, Double(tab.position) * factor))
        }
        return style
    }

    static func color(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: Double(value & 255) / 255, green: Double(value >> 8 & 255) / 255,
                blue: Double(value >> 16 & 255) / 255, alpha: 1)
    }
}
