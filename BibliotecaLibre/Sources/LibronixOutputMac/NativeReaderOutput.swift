import AppKit
import CoreText
import LibronixCore

/// Native output has no dependency on the reader's NSTextView or its temporary
/// annotation attributes. Preview, PDF and Print consume these same bytes.
@MainActor public enum NativeReaderOutput {
    public static func attributedText(_ document: ReaderOutputDocument, fontSize: Double = 10,
                                      includeCitation: Bool = true) throws -> NSAttributedString {
        guard fontSize.isFinite, (6...32).contains(fontSize) else { throw ReaderOutputError.limitExceeded }
        let result = NSMutableAttributedString()
        for (index, paragraph) in document.paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = paragraph.style?.rightToLeft == true ? .rightToLeft : .natural
            style.lineSpacing = 0; style.paragraphSpacing = 0
            if let source = paragraph.style {
                switch source.alignment {
                case .left: style.alignment = .left
                case .right: style.alignment = .right
                case .center: style.alignment = .center
                case .justified: style.alignment = .justified
                case nil: style.alignment = .natural
                }
                style.headIndent = Double(source.headIndent) / 20
                style.tailIndent = -Double(source.tailIndent) / 20
                style.firstLineHeadIndent = style.headIndent + Double(source.firstLineIndent) / 20
                style.paragraphSpacingBefore = max(0, Double(source.spaceBefore) / 20)
                style.paragraphSpacing = max(0, Double(source.spaceAfter) / 20)
                if let height = source.extraLineHeight, height < 0 {
                    style.minimumLineHeight = abs(Double(height)) / 20; style.maximumLineHeight = style.minimumLineHeight
                }
                style.tabStops = source.tabStops.map {
                    NSTextTab(textAlignment: $0.kind == 2 ? .right : .left, location: Double($0.position) / 20)
                }
            }
            let start = result.length
            let text = ReaderOutputEncoder.projectedText(paragraph.text) + (index < document.paragraphs.count - 1 ? "\n" : "")
            let font = NSFont(name: "Arial", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            result.append(NSAttributedString(string: text, attributes:[.font:font,.foregroundColor:NSColor.black,.paragraphStyle:style]))
            _ = try ReaderOutputEncoder.spans(paragraph)
            for span in paragraph.spans {
                guard let source = span.style else { continue }
                let range = NSRange(location: start + span.range.location, length: span.range.length)
                let rawPoints = Int(source.font.height / 20)
                let percentage = rawPoints > 0 && rawPoints <= 144 ? Double(rawPoints * 100 / 12) / 100 : 1
                let normalSize = min(96, max(4, fontSize * percentage))
                let smaller = source.isSuperscript || source.isSubscript
                let size = smaller ? normalSize * 0.755 : normalSize
                var font = NSFont(name:"Arial",size:size) ?? NSFont.systemFont(ofSize:size)
                if source.font.weight > 400 { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if source.font.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                result.addAttribute(.font,value:font,range:range)
                if source.font.underline { result.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:range) }
                if source.font.strikeout { result.addAttribute(.strikethroughStyle,value:NSUnderlineStyle.single.rawValue,range:range) }
                if smaller { result.addAttribute(.baselineOffset,value:source.isSuperscript ? normalSize * 0.3 : -normalSize * 0.2,range:range) }
                if source.flags & 0x40 != 0 {
                    let color = NSColor(red:Double(source.color & 0xff)/255,green:Double(source.color >> 8 & 0xff)/255,
                                        blue:Double(source.color >> 16 & 0xff)/255,alpha:1)
                    result.addAttribute(.foregroundColor,value:color,range:range)
                }
            }
        }
        if includeCitation, !document.bibliographicCitation.isEmpty {
            let style = NSMutableParagraphStyle(); style.paragraphSpacingBefore = 9
            let font = NSFont(name:"Arial-ItalicMT",size:fontSize*0.9) ?? NSFont.systemFont(ofSize:fontSize*0.9)
            result.append(NSAttributedString(string:"\n\n" + document.bibliographicCitation,
                attributes:[.font:font,.foregroundColor:NSColor.black,.paragraphStyle:style]))
        }
        return result
    }
    public static func rtf(_ document: ReaderOutputDocument, fontSize: Double = 10,
                           includeCitation: Bool = true) throws -> Data {
        let text = try attributedText(document,fontSize:fontSize,includeCitation:includeCitation)
        return try text.data(from:NSRange(location:0,length:text.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
    }
    public static func pdf(_ document: ReaderOutputDocument, settings: ReaderPrintSettings = .init(),
                           maximumPages: Int = 1_000) throws -> Data {
        try settings.validate()
        guard maximumPages > 0, maximumPages <= 1_000 else { throw ReaderOutputError.limitExceeded }
        let text = try attributedText(document,fontSize:settings.fontSize,includeCitation:true)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let width = settings.width - settings.leftMargin - settings.rightMargin
        let height = settings.height - settings.topMargin - settings.bottomMargin
        let path = CGPath(rect:CGRect(x:0,y:0,width:width,height:height),transform:nil)
        var pages: [CFRange] = [], offset = 0
        while offset < text.length {
            try Task.checkCancellation()
            guard pages.count < maximumPages else { throw ReaderOutputError.limitExceeded }
            let frame = CTFramesetterCreateFrame(framesetter,CFRange(location:offset,length:0),path,nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.location == offset, visible.length > 0, visible.length <= text.length - offset else { throw ReaderOutputError.limitExceeded }
            pages.append(visible); offset += visible.length
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data:data as CFMutableData) else { throw ReaderOutputError.limitExceeded }
        var media = CGRect(x:0,y:0,width:settings.width,height:settings.height)
        let metadata = [kCGPDFContextTitle as String:document.title,kCGPDFContextCreator as String:"Libron-X"] as CFDictionary
        guard let context = CGContext(consumer:consumer,mediaBox:&media,metadata) else { throw ReaderOutputError.limitExceeded }
        let date = DateFormatter(); date.locale = Locale(identifier:"es_ES"); date.dateFormat = "dd/MM/yyyy"
        for (index, range) in pages.enumerated() {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            context.saveGState(); context.translateBy(x:settings.leftMargin,y:settings.bottomMargin)
            let frame = CTFramesetterCreateFrame(framesetter,range,path,nil); CTFrameDraw(frame,context)
            context.restoreGState()
            let pageLabel = "Página \(index+1) de \(pages.count)"
            let pageLabelWidth = settings.pageNumbers ? min(width,lineWidth(pageLabel)) : 0
            if settings.pageNumbers { draw(pageLabel,at:CGPoint(x:settings.width-settings.rightMargin,y:settings.height-20),context:context,rightAligned:true,maximumWidth:width) }
            if settings.showTitle {
                draw(document.title,at:CGPoint(x:settings.leftMargin,y:settings.height-20),context:context,
                     maximumWidth:max(0,width-pageLabelWidth-(settings.pageNumbers ? 12 : 0)))
            }
            if settings.footer {
                draw("Libron-X",at:CGPoint(x:settings.leftMargin,y:12),context:context,maximumWidth:width/2-6)
                draw(date.string(from:document.createdUTC),at:CGPoint(x:settings.width-settings.rightMargin,y:12),context:context,rightAligned:true,maximumWidth:width/2-6)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
    private static func line(_ text: String) -> CTLine {
        let font = CTFontCreateWithName("Arial" as CFString,10,nil)
        let attributes: [NSAttributedString.Key:Any] = [.init(kCTFontAttributeName as String):font,
            .init(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]
        return CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attributes))
    }
    private static func lineWidth(_ text: String) -> Double { CTLineGetTypographicBounds(line(text),nil,nil,nil) }
    private static func draw(_ text: String, at point: CGPoint, context: CGContext, rightAligned: Bool = false, maximumWidth: Double) {
        guard maximumWidth > 0 else { return }
        var renderedLine = line(text)
        if CTLineGetTypographicBounds(renderedLine,nil,nil,nil) > maximumWidth {
            guard let shortened = CTLineCreateTruncatedLine(renderedLine,maximumWidth,.end,line("…")) else { return }
            renderedLine = shortened
        }
        let width = CTLineGetTypographicBounds(renderedLine,nil,nil,nil)
        context.textPosition = CGPoint(x:point.x-(rightAligned ? width : 0),y:point.y); CTLineDraw(renderedLine,context)
    }
}
