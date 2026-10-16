import Foundation

public enum ReaderOutputEncoder {
    /// The one-unit zero-width conversion is verified in the original writer.
    /// Apply it only to output; source offsets and fingerprints remain raw.
    public static func projectedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200b}", with: "\u{feff}")
    }
    public static func text(_ document: ReaderOutputDocument, includeCitation: Bool = false) -> Data {
        var text = projectedText(document.plainText)
        if includeCitation { text += "\n\n" + document.bibliographicCitation }
        return Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }
    public static func html(_ document: ReaderOutputDocument, includeCitation: Bool = false) throws -> Data {
        let body = try document.paragraphs.map { paragraph in
            let style = paragraph.style.map(paragraphCSS) ?? ""
            let direction = paragraph.style?.rightToLeft == true ? "rtl" : "auto"
            let content = try spans(paragraph).map { text, style in
                var content = escape(projectedText(text)).replacingOccurrences(of: "\u{2028}", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>")
                guard let style else { return content }
                let css = characterCSS(style)
                if !css.isEmpty { content = "<span style=\"\(css)\">\(content)</span>" }
                if style.isSuperscript { content = "<sup>\(content)</sup>" }
                if style.isSubscript { content = "<sub>\(content)</sub>" }
                if style.font.italic { content = "<i>\(content)</i>" }
                if style.font.weight > 400 { content = "<b>\(content)</b>" }
                return content
            }.joined()
            return "<div dir=\"\(direction)\" style=\"\(style)\">\(content)</div>"
        }.joined(separator: "\n")
        let citation = includeCitation ? "<hr><p class=\"citation\"><i>\(escape(document.bibliographicCitation))</i></p>" : ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="generator" content="Libron-X">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'">
        <title>\(escape(document.title))</title><style>body{font-family:Arial,Helvetica,sans-serif}div{white-space:pre-wrap}sup,sub{font-size:75.5%}.citation{font-size:90%}</style>
        </head><body>\(body)\(citation)</body></html>
        """
        return Data(html.utf8)
    }
    /// Preserve source run boundaries, including unstyled gaps, without
    /// allowing overlapping/out-of-bounds spans to replace book content.
    public static func spans(_ paragraph: ReaderOutputParagraph) throws -> [(String, LegacyCharacterStyle?)] {
        let text = paragraph.text as NSString
        var result: [(String, LegacyCharacterStyle?)] = [], offset = 0
        for span in paragraph.spans {
            let range = span.range
            guard range.location >= offset, range.length > 0, range.location <= text.length,
                  range.length <= text.length - range.location else { throw ReaderOutputError.invalidSelection }
            if range.location > offset { result.append((text.substring(with: NSRange(location: offset, length: range.location - offset)), nil)) }
            result.append((text.substring(with: range.nsRange), span.style)); offset = range.upperBound
        }
        if offset < text.length { result.append((text.substring(from: offset), nil)) }
        return result
    }
    private static func paragraphCSS(_ style: LegacyParagraphStyle) -> String {
        var values: [String] = []
        if let alignment = style.alignment { values.append("text-align:\(alignment == .justified ? "justify" : alignment.rawValue)") }
        if style.rightToLeft { values.append("direction:rtl") }
        for (key, value) in [("text-indent",style.firstLineIndent),("margin-left",style.headIndent),("margin-right",style.tailIndent),
                             ("margin-top",style.spaceBefore),("margin-bottom",style.spaceAfter)] where value != 0 {
            values.append("\(key):\(Int(value) / 20)pt")
        }
        if let line = style.extraLineHeight, line < 0 { values.append("line-height:\(abs(Int(line)) / 20)pt") }
        for (side, border) in zip(["left","right","top","bottom"], style.borders) where border.width > 0 {
            let type = border.kind == 4 ? "double" : border.kind == 5 ? "dotted" : border.kind == 6 ? "dashed" : "solid"
            values.append("border-\(side):\(max(1, Int(border.width) / 20))pt \(type) #\(color(border.color))")
            if border.padding != 0 { values.append("padding-\(side):\(Int(border.padding) / 20)pt") }
        }
        return values.joined(separator: ";")
    }
    private static func characterCSS(_ style: LegacyCharacterStyle) -> String {
        var values: [String] = []
        let points = Int(style.font.height / 20)
        if points > 0, points <= 144, points != 12 { values.append("font-size:\(points * 100 / 12)%") }
        if style.font.underline { values.append("text-decoration:underline") }
        if style.font.strikeout { values.append("text-decoration:line-through") }
        if style.smallCaps { values.append("font-variant:small-caps") }
        if style.capitalizeWords { values.append("text-transform:capitalize") }
        if style.flags & 0x40 != 0 { values.append("color:#\(color(style.color))") }
        return values.joined(separator: ";")
    }
    private static func color(_ color: UInt32) -> String {
        String(format: "%02x%02x%02x", color & 0xff, color >> 8 & 0xff, color >> 16 & 0xff)
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
