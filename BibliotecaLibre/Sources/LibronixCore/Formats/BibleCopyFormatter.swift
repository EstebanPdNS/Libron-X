import Foundation

public enum BibleCopyReferenceLanguage: String, Codable, CaseIterable, Sendable { case english, spanish }
public enum BibleCopyDirection: String, Sendable { case natural, leftToRight, rightToLeft }
public struct BibleCopyTextFormat: Sendable, Equatable {
    public var bold=false, italic=false, underline=false, superscript=false, subscriptText=false
    public init() {}
}
public struct BibleCopyFormattedRun: Sendable, Equatable {
    public var text: String
    public var sourceStyle: LegacyCharacterStyle?
    public var format: BibleCopyTextFormat
    public var footnoteID: String?
}
public struct BibleCopyFormattedParagraph: Sendable, Equatable {
    public var runs: [BibleCopyFormattedRun]
    public var sourceStyle: LegacyParagraphStyle?
    public var direction: BibleCopyDirection
    public var text: String { runs.map(\.text).joined() }
}
public struct BibleCopyFormattedNote: Sendable, Equatable {
    public let id: String
    public let marker: String
    public let text: String
    public let isCitation: Bool
}
public struct BibleCopyFormattedDocument: Sendable, Equatable {
    public let title: String
    public let style: BibleCopyOutputStyle
    public let paragraphs: [BibleCopyFormattedParagraph]
    public let notes: [BibleCopyFormattedNote]
    public let sources: [ReaderOutputSource]
    public var bodyText: String { paragraphs.map(\.text).joined(separator:"\n\n") }
    public var plainText: String {
        bodyText + notes.map { "\n\n"+$0.marker+" "+$0.text }.joined()
    }
}

/// Templates and the source body take different paths: only literal template
/// tags b/i/u/sup/sub change formatting. Book text and expanded names stay text.
public enum BibleCopyFormatter {
    public static func format(_ document:BibleCopyDocument, style:BibleCopyOutputStyle,
                              referenceLanguage:BibleCopyReferenceLanguage = .english) throws -> BibleCopyFormattedDocument {
        try style.validate();try Task.checkCancellation()
        let rangeName=BibleCopyReferenceNames.passage(document.passage,last:document.verses.last?.address,language:referenceLanguage,short:false)
        let shortRange=BibleCopyReferenceNames.passage(document.passage,last:document.verses.last?.address,language:referenceLanguage,short:true)
        func context(_ address:BibleCopyAddress) -> BibleCopyOutputTemplateContext {
            let names=BibleCopyReferenceNames.book(address,language:referenceLanguage)
            return .init(passage:rangeName,fullReference:"\(names.full) \(address.chapter):\(address.verse)",
                shortReference:"\(names.short) \(address.chapter):\(address.verse)",fullBook:names.full,shortBook:names.short,
                chapter:address.chapter,verse:address.verse,abbreviation:document.abbreviation,shortPassage:shortRange)
        }
        var paragraphs:[BibleCopyFormattedParagraph]=[],notes:[BibleCopyFormattedNote]=[]
        func template(_ value:BibleCopyOutputTemplate,_ address:BibleCopyAddress) throws -> [BibleCopyFormattedRun] {
            try templateRuns(value,context:context(address))
        }
        func body(_ fragments:[BibleCopyFragment],trim:Bool) throws -> [BibleCopyFormattedRun] {
            var result:[BibleCopyFormattedRun]=[]
            for fragment in fragments {
                if let note=fragment.footnote {
                    guard style.copyFootnotes else { continue }
                    guard let source=document.footnotes.first(where:{$0.id==note}) else { throw BibleCopyError.missingBoundary }
                    if !notes.contains(where:{$0.id==note}) { notes.append(.init(id:note,marker:try project(source.marker,style:style),text:try project(source.text,style:style),isCitation:false)) }
                } else if style.bibleTextOnly && !fragment.isBibleText { continue }
                let text=try project(fragment.text,style:style)
                guard !text.isEmpty else { continue }
                result.append(.init(text:text,sourceStyle:fragment.style,format:.init(),footnoteID:fragment.footnote))
            }
            if trim {
                // This mirrors the first/last Bible text node trimming, rather
                // than changing the source or trimming a reference/footnote.
                if let first=result.firstIndex(where:{$0.footnoteID==nil}) {
                    result[first].text=result[first].text.replacingOccurrences(of:"^\\s+",with:"",options:.regularExpression)
                }
                if let last=result.lastIndex(where:{$0.footnoteID==nil}) {
                    result[last].text=result[last].text.replacingOccurrences(of:"\\s+$",with:"",options:.regularExpression)
                }
            }
            return result
        }
        func paragraph(_ runs:[BibleCopyFormattedRun],_ source:LegacyParagraphStyle?) -> BibleCopyFormattedParagraph {
            let text=runs.map(\.text).joined()
            let hebrew=text.unicodeScalars.contains{(0x0590...0x05ff).contains($0.value)}
            let transliterated=style.hebrew == .transliterated && document.sourceLanguages.contains(where:{$0.lowercased().hasPrefix("he")})
            return .init(runs:runs,sourceStyle:style.paragraphFormatting ? source:nil,
                direction:hebrew ? .rightToLeft:transliterated ? .leftToRight:source?.rightToLeft == true ? .rightToLeft:.natural)
        }
        if document.hasVerseText {
            if style.bibleTextOnly && style.paragraphs != .sourceParagraphs {
                var runs=try template(style.beforePassage,document.passage.start)
                for (index,verse) in document.verses.enumerated() {
                    try Task.checkCancellation()
                    runs += try template(style.beforeVerse,verse.address)
                    runs += try body(verse.fragments,trim:true)
                    runs += try template(style.afterVerse,verse.address)
                    if index+1 < document.verses.count && !style.afterVerse.pattern.contains("^n") &&
                        !document.sourceLanguages.contains(where:{["ja","ko","th","zh"].contains($0.lowercased())}) {
                        runs.append(.init(text:" ",sourceStyle:nil,format:.init(),footnoteID:nil))
                    }
                }
                runs += try template(style.afterPassage,document.passage.start)
                paragraphs.append(paragraph(runs,document.verses.first?.paragraphStyle))
            } else {
                guard !document.sourceParagraphs.isEmpty else { throw BibleCopyError.incompleteSource }
                if !style.bibleTextOnly { paragraphs.append(paragraph(try template(style.beforePassage,document.passage.start),nil)) }
                for source in document.sourceParagraphs {
                    try Task.checkCancellation()
                    var runs:[BibleCopyFormattedRun]=[]
                    if style.bibleTextOnly {
                        var marks=source.marks
                        for fragment in source.fragments {
                            while let mark=marks.first,mark.offset<=fragment.sourceRange.location {
                                runs += try template(style.beforeVerse,mark.address);marks.removeFirst()
                            }
                            // An anchor inside a text run needs an explicit split;
                            // do not silently put the reference in the wrong place.
                            guard !marks.contains(where:{$0.offset<fragment.sourceRange.upperBound}) else { throw BibleCopyError.missingBoundary }
                            runs += try body([fragment],trim:false)
                        }
                    } else { runs=try body(source.fragments,trim:false) }
                    if !runs.isEmpty { paragraphs.append(paragraph(runs,source.style)) }
                }
                if style.bibleTextOnly, !paragraphs.isEmpty {
                    paragraphs[0].runs.insert(contentsOf:try template(style.beforePassage,document.passage.start),at:0)
                    paragraphs[paragraphs.count-1].runs += try template(style.afterPassage,document.passage.start)
                } else { paragraphs.append(paragraph(try template(style.afterPassage,document.passage.start),nil)) }
            }
        }
        if style.citation && !document.citation.isEmpty {
            if !paragraphs.isEmpty {
                var format=BibleCopyTextFormat();format.superscript=true
                paragraphs[paragraphs.count-1].runs.append(.init(text:"[1]",sourceStyle:nil,format:format,footnoteID:"citation"))
            }
            notes.append(.init(id:"citation",marker:"[1]",text:document.citation,isCitation:true))
        }
        return .init(title:rangeName,style:style,paragraphs:paragraphs,notes:notes,sources:document.sources)
    }
    private static func project(_ text:String,style:BibleCopyOutputStyle) throws -> String {
        var result=text.replacingOccurrences(of:"\u{200b}",with:"").replacingOccurrences(of:"\u{feff}",with:"")
        if style.bibleTextOnly && style.paragraphs != .sourceParagraphs { result=result.replacingOccurrences(of:"\u{200d}",with:"") }
        if result.unicodeScalars.contains(where:{(0x0590...0x05ff).contains($0.value)}) {
            guard style.hebrew == .unicode || style.hebrew == .transliterated else { throw BibleCopyError.unsupportedLanguage }
            result=BibleCopyScriptProjection.hebrew(result,letters:style.hebrewLetters)
            if style.hebrew == .transliterated { result=BibleCopyTransliterator.hebrewLogos(result) }
        }
        if style.greek == .transliterated && result.unicodeScalars.contains(where:{(0x0370...0x03ff).contains($0.value) || (0x1f00...0x1fff).contains($0.value)}) {
            result=BibleCopyTransliterator.greekSBL(result)
        }
        return result
    }
    public static func templateRuns(_ template:BibleCopyOutputTemplate,context:BibleCopyOutputTemplateContext?) throws -> [BibleCopyFormattedRun] {
        try BibleCopyOutputTemplateExpander.validate(template.pattern)
        let pattern=template.pattern as NSString
        let expression=try NSRegularExpression(pattern:"</?(b|i|u|sup|sub)>",options:.caseInsensitive)
        let matches=expression.matches(in:template.pattern,range:NSRange(location:0,length:pattern.length))
        var counts:[String:Int]=[:],cursor=0,result:[BibleCopyFormattedRun]=[]
        func append(_ text:String) throws {
            guard !text.isEmpty else { return }
            var flags=BibleCopyTextFormat()
            flags.bold=template.bold || counts["b",default:0]>0;flags.italic=template.italic || counts["i",default:0]>0
            flags.underline=template.underline || counts["u",default:0]>0
            flags.superscript=template.superscript || counts["sup",default:0]>0
            flags.subscriptText=template.subscriptText || counts["sub",default:0]>0
            result.append(.init(text:try BibleCopyOutputTemplateExpander.expand(text,context:context),sourceStyle:nil,format:flags,footnoteID:nil))
        }
        for match in matches {
            try append(pattern.substring(with:NSRange(location:cursor,length:match.range.location-cursor)))
            let name=pattern.substring(with:match.range(at:1)).lowercased(),closing=pattern.substring(with:match.range).hasPrefix("</")
            counts[name,default:0]=closing ? max(0,counts[name,default:0]-1):counts[name,default:0]+1
            cursor=match.range.location+match.range.length
        }
        try append(pattern.substring(from:cursor));return result
    }
}

public enum BibleCopyReferenceNames {
    // Independent ES/EN labels. Exact datatype-renderer punctuation for every
    // original locale remains a separate comparison, not a numeric-ID table.
    private static let labels:[String:(String,String)] = [
        "ge":("Genesis","Génesis"),"ex":("Exodus","Éxodo"),"le":("Leviticus","Levítico"),"nu":("Numbers","Números"),"dt":("Deuteronomy","Deuteronomio"),
        "jos":("Joshua","Josué"),"jdg":("Judges","Jueces"),"ru":("Ruth","Rut"),"1sa":("1 Samuel","1 Samuel"),"2sa":("2 Samuel","2 Samuel"),
        "1ki":("1 Kings","1 Reyes"),"2ki":("2 Kings","2 Reyes"),"1ch":("1 Chronicles","1 Crónicas"),"2ch":("2 Chronicles","2 Crónicas"),"ezr":("Ezra","Esdras"),
        "ne":("Nehemiah","Nehemías"),"es":("Esther","Ester"),"job":("Job","Job"),"ps":("Psalms","Salmos"),"pr":("Proverbs","Proverbios"),
        "ec":("Ecclesiastes","Eclesiastés"),"so":("Song of Songs","Cantares"),"is":("Isaiah","Isaías"),"je":("Jeremiah","Jeremías"),"la":("Lamentations","Lamentaciones"),
        "eze":("Ezekiel","Ezequiel"),"da":("Daniel","Daniel"),"ho":("Hosea","Oseas"),"joe":("Joel","Joel"),"am":("Amos","Amós"),"ob":("Obadiah","Abdías"),
        "jon":("Jonah","Jonás"),"mic":("Micah","Miqueas"),"na":("Nahum","Nahúm"),"hab":("Habakkuk","Habacuc"),"zep":("Zephaniah","Sofonías"),
        "hag":("Haggai","Hageo"),"zec":("Zechariah","Zacarías"),"mal":("Malachi","Malaquías"),"mt":("Matthew","Mateo"),"mk":("Mark","Marcos"),
        "lk":("Luke","Lucas"),"jn":("John","Juan"),"ac":("Acts","Hechos"),"ro":("Romans","Romanos"),"1co":("1 Corinthians","1 Corintios"),"2co":("2 Corinthians","2 Corintios"),
        "ga":("Galatians","Gálatas"),"eph":("Ephesians","Efesios"),"php":("Philippians","Filipenses"),"col":("Colossians","Colosenses"),
        "1th":("1 Thessalonians","1 Tesalonicenses"),"2th":("2 Thessalonians","2 Tesalonicenses"),"1ti":("1 Timothy","1 Timoteo"),"2ti":("2 Timothy","2 Timoteo"),
        "tt":("Titus","Tito"),"phm":("Philemon","Filemón"),"heb":("Hebrews","Hebreos"),"jas":("James","Santiago"),"1pe":("1 Peter","1 Pedro"),"2pe":("2 Peter","2 Pedro"),
        "1jn":("1 John","1 Juan"),"2jn":("2 John","2 Juan"),"3jn":("3 John","3 Juan"),"jud":("Jude","Judas"),"re":("Revelation","Apocalipsis")]
    public static func book(_ address:BibleCopyAddress,language:BibleCopyReferenceLanguage) -> (full:String,short:String) {
        let label=labels[address.bookKey]
        let full=language == .english ? label?.0:label?.1
        let key=address.bookKey
        let firstLetter=key.firstIndex(where:{$0.isLetter})
        let short=label == nil ? address.sourceBook:firstLetter.map{String(key[..<$0])+String(key[$0]).uppercased()+key[key.index(after:$0)...]} ?? key
        return (full ?? address.sourceBook,short)
    }
    public static func passage(_ passage:BibleCopyPassage,last:BibleCopyAddress?,language:BibleCopyReferenceLanguage,short:Bool) -> String {
        let start=passage.start,end=last ?? passage.end,names=book(start,language:language),bookName=short ? names.short:names.full
        if passage.wholeChapter { return "\(bookName) \(start.chapter)" }
        let prefix="\(bookName) \(start.chapter):\(start.verse)"
        if start==end { return prefix }
        if start.bookKey==end.bookKey { return prefix+"–"+(start.chapter==end.chapter ? "\(end.verse)":"\(end.chapter):\(end.verse)") }
        let tail=book(end,language:language)
        return prefix+"–\(short ? tail.short:tail.full) \(end.chapter):\(end.verse)"
    }
}
