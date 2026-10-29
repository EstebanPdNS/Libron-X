import AppKit
import LibronixCore

@MainActor public struct NativeBibleCopyPayload {
    public let document: BibleCopyFormattedDocument
    public let preview: NSAttributedString
    public let text: String
    public let rtf: Data
    public let footnoteRTF: Data
    public let html: Data
}

/// One frozen semantic document supplies all clipboard representations. RTF
/// footnotes are structural; the native preview shows their text underneath.
@MainActor public enum NativeBibleCopyOutput {
    public static func prepare(_ document:BibleCopyFormattedDocument,fontSize:Double = 12) throws -> NativeBibleCopyPayload {
        guard fontSize.isFinite,(6...32).contains(fontSize) else { throw BibleCopyError.limitExceeded }
        let preview=try attributed(document,fontSize:fontSize)
        // AppKit's RTF reader drops structural footnote destinations. General
        // Mac paste therefore includes visible endnotes, preserving the entire
        // preview. Keep structural RTF separately for capable destinations.
        let rtf=try preview.data(from:NSRange(location:0,length:preview.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        return .init(document:document,preview:preview,text:document.plainText,rtf:rtf,
                     footnoteRTF:try richText(document,fontSize:fontSize),html:try html(document,fontSize:fontSize))
    }
    private static func color(_ run:BibleCopyFormattedRun,style:BibleCopyOutputStyle) -> UInt32 {
        guard let source=run.sourceStyle,source.flags & 0x40 != 0 else { return 0 }
        if source.color & 0xffffff == 0x0000ff { return style.redLetter ? source.color & 0xffffff:0 }
        return style.characterFormatting ? source.color & 0xffffff:0
    }
    private static func format(_ run:BibleCopyFormattedRun,style:BibleCopyOutputStyle) -> BibleCopyTextFormat {
        var result=run.format
        if style.characterFormatting,let source=run.sourceStyle {
            result.bold = result.bold || source.font.weight>400
            result.italic = result.italic || source.font.italic
            result.underline = result.underline || source.font.underline
            result.superscript = result.superscript || source.isSuperscript
            result.subscriptText = result.subscriptText || source.isSubscript
        }
        return result
    }
    private static func family(_ text:String) -> String {
        if text.unicodeScalars.contains(where:{(0x0590...0x05ff).contains($0.value)}) { return "SBL Hebrew" }
        if text.unicodeScalars.contains(where:{(0x0370...0x03ff).contains($0.value) || (0x1f00...0x1fff).contains($0.value)}) { return "Gentium" }
        return "Arial"
    }
    private static func paragraphStyle(_ paragraph:BibleCopyFormattedParagraph) -> NSMutableParagraphStyle {
        let result=NSMutableParagraphStyle();result.paragraphSpacing=0
        result.baseWritingDirection=paragraph.direction == .rightToLeft ? .rightToLeft:paragraph.direction == .leftToRight ? .leftToRight:.natural
        if let source=paragraph.sourceStyle {
            switch source.alignment { case .left:result.alignment = .left;case .right:result.alignment = .right;case .center:result.alignment = .center;case .justified:result.alignment = .justified;case nil:break }
            result.headIndent=Double(source.headIndent)/20;result.tailIndent = -Double(source.tailIndent)/20
            result.firstLineHeadIndent=result.headIndent+Double(source.firstLineIndent)/20
            result.paragraphSpacingBefore=max(0,Double(source.spaceBefore)/20);result.paragraphSpacing=max(0,Double(source.spaceAfter)/20)
            result.tabStops=source.tabStops.map{NSTextTab(textAlignment:$0.kind==2 ? .right:.left,location:Double($0.position)/20)}
        }
        if paragraph.direction == .leftToRight,paragraph.sourceStyle?.rightToLeft == true { result.alignment = .left }
        return result
    }
    private static func attributes(_ run:BibleCopyFormattedRun,style:BibleCopyOutputStyle,fontSize:Double) -> [NSAttributedString.Key:Any] {
        let flags=format(run,style:style),smaller=flags.superscript || flags.subscriptText
        var font=NSFont(name:family(run.text),size:fontSize*(smaller ? 0.755:1)) ?? NSFont.systemFont(ofSize:fontSize*(smaller ? 0.755:1))
        if flags.bold { font=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask) }
        if flags.italic { font=NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask) }
        let rgb=color(run,style:style)
        var result:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:NSColor(red:Double(rgb & 255)/255,green:Double(rgb>>8 & 255)/255,blue:Double(rgb>>16 & 255)/255,alpha:1)]
        if flags.underline { result[.underlineStyle]=NSUnderlineStyle.single.rawValue }
        if flags.subscriptText { result[.baselineOffset] = -fontSize*0.2 }
        else if flags.superscript { result[.baselineOffset]=fontSize*0.3 }
        if style.characterFormatting && run.sourceStyle?.font.strikeout == true { result[.strikethroughStyle]=NSUnderlineStyle.single.rawValue }
        return result
    }
    private static func attributed(_ document:BibleCopyFormattedDocument,fontSize:Double) throws -> NSAttributedString {
        let result=NSMutableAttributedString()
        for (index,paragraph) in document.paragraphs.enumerated() {
            try Task.checkCancellation()
            if index>0 { result.append(NSAttributedString(string:"\n\n")) }
            let start=result.length
            for run in paragraph.runs { result.append(NSAttributedString(string:run.text,attributes:attributes(run,style:document.style,fontSize:fontSize))) }
            result.addAttribute(.paragraphStyle,value:paragraphStyle(paragraph),range:NSRange(location:start,length:result.length-start))
        }
        for note in document.notes {
            let paragraph=NSMutableParagraphStyle();paragraph.baseWritingDirection = .leftToRight
            result.append(NSAttributedString(string:"\n\n"+note.marker+" "+note.text,
                attributes:[.font:NSFont.systemFont(ofSize:fontSize*0.9),.foregroundColor:NSColor.black,.paragraphStyle:paragraph]))
        }
        guard result.string==document.plainText else { throw BibleCopyError.incompleteSource }
        return result
    }
    private static func escaped(_ value:String) -> String {
        value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
    }
    private static func html(_ document:BibleCopyFormattedDocument,fontSize:Double) throws -> Data {
        let identities=Dictionary(uniqueKeysWithValues:document.notes.enumerated().map{($0.element.id,"n\($0.offset+1)")})
        var body=""
        for paragraph in document.paragraphs {
            try Task.checkCancellation()
            let direction=paragraph.direction == .rightToLeft ? "rtl":"ltr"
            let source=paragraph.sourceStyle
            let alignment=paragraph.direction == .leftToRight && source?.rightToLeft == true ? "left":source?.alignment?.rawValue ?? "start"
            body += "<p dir=\"\(direction)\" style=\"margin:0;text-align:\(alignment);font-size:\(fontSize)pt;\">"
            for run in paragraph.runs {
                let flags=format(run,style:document.style),rgb=color(run,style:document.style)
                let hex=String(format:"#%02x%02x%02x",rgb & 255,rgb>>8 & 255,rgb>>16 & 255)
                var text=escaped(run.text).replacingOccurrences(of:"\n",with:"<br>").replacingOccurrences(of:"\u{2028}",with:"<br>")
                if flags.bold { text="<b>"+text+"</b>" };if flags.italic { text="<i>"+text+"</i>" }
                if flags.underline { text="<u>"+text+"</u>" };if flags.superscript { text="<sup>"+text+"</sup>" }
                if flags.subscriptText { text="<sub>"+text+"</sub>" }
                if document.style.characterFormatting && run.sourceStyle?.font.strikeout == true { text="<s>"+text+"</s>" }
                if let note=run.footnoteID,let identity=identities[note] { text="<a href=\"#\(identity)\" style=\"mso-footnote-id:\(identity)\">"+text+"</a>" }
                body += "<span style=\"font-family:'\(family(run.text))';color:\(hex);\">"+text+"</span>"
            }
            body += "</p>"
        }
        if !document.notes.isEmpty {
            body += "<div style=\"mso-element:footnote-list;\">"
            for note in document.notes { body += "<div id=\"\(identities[note.id]!)\" style=\"mso-element:footnote;\"><p>\(escaped(note.marker)) \(escaped(note.text))</p></div>" }
            body += "</div>"
        }
        let html="<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>\(escaped(document.title))</title></head><body><!--StartFragment-->\(body)<!--EndFragment--></body></html>"
        return Data(html.utf8)
    }
    private static func rtfText(_ value:String) -> String {
        value.utf16.map { unit in
            switch unit {
            case 92:return "\\\\";case 123:return "\\{";case 125:return "\\}"
            case 10,0x2028:return "\\line ";case 13:return "";case 9:return "\\tab "
            case 32...126:return String(UnicodeScalar(unit)!)
            default:return "\\u\(Int16(bitPattern:unit))?"
            }
        }.joined()
    }
    private static func richText(_ document:BibleCopyFormattedDocument,fontSize:Double) throws -> Data {
        var colors:[UInt32]=[0]
        for run in document.paragraphs.flatMap(\.runs) { let rgb=color(run,style:document.style);if !colors.contains(rgb) { colors.append(rgb) } }
        let colorTable=colors.map{"\\red\($0 & 255)\\green\($0>>8 & 255)\\blue\($0>>16 & 255);"}.joined()
        var result="{\\rtf1\\ansi\\deff0\\uc1{\\fonttbl{\\f0 Arial;}{\\f1 SBL Hebrew;}{\\f2 Gentium;}}{\\colortbl;\(colorTable)}"
        var emitted=Set<String>()
        for (index,paragraph) in document.paragraphs.enumerated() {
            try Task.checkCancellation()
            if index>0 { result += "\\par\n" }
            result += "\\pard"+(paragraph.direction == .rightToLeft ? "\\rtlpar":"\\ltrpar")
            if let source=paragraph.sourceStyle {
                let alignment=paragraph.direction == .leftToRight && source.rightToLeft ? LegacyTextAlignment.left:source.alignment
                switch alignment { case .left:result += "\\ql";case .right:result += "\\qr";case .center:result += "\\qc";case .justified:result += "\\qj";case nil:break }
                result += "\\li\(source.headIndent)\\ri\(source.tailIndent)\\fi\(source.firstLineIndent)\\sb\(max(0,source.spaceBefore))\\sa\(max(0,source.spaceAfter))"
                for tab in source.tabStops { result += (tab.kind==2 ? "\\tqr":"\\tql")+"\\tx\(tab.position)" }
            }
            result += " "
            for run in paragraph.runs {
                let flags=format(run,style:document.style),font=family(run.text),fontID=font=="SBL Hebrew" ? 1:font=="Gentium" ? 2:0
                let colorID=(colors.firstIndex(of:color(run,style:document.style)) ?? 0)+1
                result += "{\\plain\\f\(fontID)\\fs\(Int((fontSize*2).rounded()))\\cf\(colorID)"
                if flags.bold { result += "\\b" };if flags.italic { result += "\\i" };if flags.underline { result += "\\ul" }
                if flags.subscriptText { result += "\\sub" } else if flags.superscript { result += "\\super" }
                if document.style.characterFormatting && run.sourceStyle?.font.strikeout == true { result += "\\strike" }
                result += " "+rtfText(run.text)+"}"
                if let id=run.footnoteID,!emitted.contains(id),let note=document.notes.first(where:{$0.id==id}) {
                    result += "{\\footnote\\pard\\ltrpar\\plain\\f0\\fs\(Int((fontSize*1.8).rounded())) "+rtfText(note.marker+" "+note.text)+"}";emitted.insert(id)
                }
            }
        }
        for note in document.notes where !emitted.contains(note.id) { result += "\\par\\pard\\ltrpar\\plain\\f0 "+rtfText(note.marker+" "+note.text) }
        result += "}"
        return Data(result.utf8)
    }
    public static func copy(_ payload:NativeBibleCopyPayload,to pasteboard:NSPasteboard = .general) throws {
        try Task.checkCancellation()
        let item=NSPasteboardItem()
        guard item.setString(payload.text,forType:.string),item.setData(payload.rtf,forType:.rtf),item.setData(payload.html,forType:.html) else { throw BibleCopyError.incompleteSource }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw BibleCopyError.incompleteSource }
    }
}
