import AppKit
import LibronixCore

/// Native HTML/RTF presentation is adapted to the reader's appearance. Original
/// text attributes and source bytes remain available for lossless inspection.
@MainActor enum ImportedTypography {
    static func normalize(_ source: NSAttributedString, repairCharacters: Bool = false) -> (text: NSMutableAttributedString, repairs: Int) {
        let result = NSMutableAttributedString(attributedString: source)
        let repaired = repairCharacters ? ImportFormattingPipeline.repairLegacyCharacters(source.string) : .init(text: source.string, repairedCharacters: 0)
        if repaired.repairedCharacters > 0 {
            // Attribute runs are unchanged because these repairs preserve UTF-16.
            let before = source.string as NSString, after = repaired.text as NSString
            for index in (0..<after.length).reversed() where before.character(at: index) != after.character(at: index) {
                let range = NSRange(location: index, length: 1)
                result.replaceCharacters(in: range, with: after.substring(with: range))
            }
        }
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttributes(in: full) { attributes, range, _ in
            if let color = attributes[.foregroundColor] as? NSColor { result.addAttribute(.foregroundColor, value: adaptive(color), range: range) }
            else { result.addAttribute(.foregroundColor, value: NSColor.textColor, range: range) }
            if let background = attributes[.backgroundColor] as? NSColor,
               let rgb = background.usingColorSpace(.sRGB), neutral(rgb) { result.removeAttribute(.backgroundColor, range: range) }
            if let font = attributes[.font] as? NSFont, !font.pointSize.isFinite || !(6...72).contains(font.pointSize) {
                result.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: min(72, max(6, font.pointSize.isFinite ? font.pointSize : 12))), range: range)
            }
        }
        return (result, repaired.repairedCharacters)
    }
    static func scaleParagraphs(_ result: NSMutableAttributedString, scale: Double) {
        guard scale != 1 else { return }
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attributes, range, _ in
            if let source = attributes[.paragraphStyle] as? NSParagraphStyle,
               let paragraph = source.mutableCopy() as? NSMutableParagraphStyle {
                paragraph.headIndent *= scale; paragraph.firstLineHeadIndent *= scale; paragraph.tailIndent *= scale
                paragraph.paragraphSpacing *= scale; paragraph.paragraphSpacingBefore *= scale; paragraph.lineSpacing *= scale
                paragraph.minimumLineHeight *= scale; paragraph.maximumLineHeight *= scale
                paragraph.tabStops = source.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location * scale, options: $0.options) }
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
            if let baseline = attributes[.baselineOffset] as? NSNumber { result.addAttribute(.baselineOffset, value: baseline.doubleValue * scale, range: range) }
        }
    }
    private static func neutral(_ color: NSColor) -> Bool {
        max(color.redComponent, color.greenComponent, color.blueComponent) - min(color.redComponent, color.greenComponent, color.blueComponent) < 0.045
    }
    static func adaptive(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .textColor }
        let red = rgb.redComponent, green = rgb.greenComponent, blue = rgb.blueComponent, alpha = rgb.alphaComponent
        if neutral(rgb) { return (max(red, green, blue) > 0.25 && max(red, green, blue) < 0.75) ? .secondaryLabelColor : .textColor }
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let background = dark ? 0.012 : 1.0
            func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
                func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            }
            func contrast(_ r: Double, _ g: Double, _ b: Double) -> Double {
                let value = luminance(r,g,b)
                return (max(background,value)+0.05)/(min(background,value)+0.05)
            }
            if contrast(red,green,blue) >= 4.5 { return NSColor(srgbRed:red,green:green,blue:blue,alpha:alpha) }
            let target = dark ? 1.0 : 0.0
            var low = 0.0, high = 1.0
            for _ in 0..<12 {
                let amount = (low+high)/2
                if contrast(red+(target-red)*amount,green+(target-green)*amount,blue+(target-blue)*amount) >= 4.5 { high = amount } else { low = amount }
            }
            return NSColor(srgbRed:red+(target-red)*high,green:green+(target-green)*high,blue:blue+(target-blue)*high,alpha:alpha)
        }
    }
}
