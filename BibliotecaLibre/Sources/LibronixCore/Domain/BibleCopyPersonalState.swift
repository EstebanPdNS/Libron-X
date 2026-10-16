import Foundation

public struct BibleCopyPersonalState: Codable, Equatable, Sendable {
    public var schemaVersion=1
    public var customStyles:[BibleCopyOutputStyle]=[]
    public var selectedStyleID=BibleCopyOutputStyle.defaults[1].id
    public var resourceID:String?
    public var passage="John 1:1"
    public var keepOpen=false
    public var referenceLanguage=BibleCopyReferenceLanguage.english
    public init() {}
    public var styles:[BibleCopyOutputStyle] { BibleCopyOutputStyle.defaults+customStyles }
    public func validate() throws {
        guard schemaVersion==1 else { throw PersonalStateError.futureVersion }
        guard customStyles.count<=1_024,passage.utf16.count<=512,(resourceID?.utf8.count ?? 0)<=16_384,
              Set(styles.map(\.id)).count==styles.count,styles.contains(where:{$0.id==selectedStyleID}) else { throw BibleCopyError.invalidStyle }
        for style in customStyles { guard style.preset==nil else { throw BibleCopyError.invalidStyle };try style.validate() }
    }
}

extension BibleCopyOutputStyle {
    /// A new XML document is a copy owned by the user. Original mixed content
    /// and unknown fields are retained in provenance and where applicable here.
    public func exportedXML() throws -> Data {
        try validate()
        func value(_ name:String,_ text:String,attributes:[String:String] = [:]) -> XMLNode {
            .init(name:name,attributes:attributes,content:[.text(text)])
        }
        func section(_ name:String,_ replacement:[XMLNode],key:String? = nil) -> XMLNode {
            let source=sourceXML?.child(named:name),keys=Set(replacement.compactMap{$0.attributes[key ?? "name"]})
            let retained=source?.content.filter { item in
                guard case let .element(node)=item else { return true }
                return !keys.contains(node.attributes[key ?? "name"] ?? "")
            } ?? []
            return .init(name:name,attributes:source?.attributes ?? [:],content:retained+replacement.map{.element($0)})
        }
        let options:[(String,Bool)]=[("CharacterFormatting",characterFormatting),("ParagraphFormatting",paragraphFormatting),
            ("RedLetter",redLetter),("BibliographicCitation",citation),("CopyFootnotes",copyFootnotes),("BibleTextOnly",bibleTextOnly),
            ("BTORemoveParagraphs",paragraphs != .sourceParagraphs)]
        let optionsNode=section("options",options.map{value("option",$0.1 ? "true":"false",attributes:["name":$0.0])})
        let templates:[(String,BibleCopyOutputTemplate)]=[("BeforePassage",beforePassage),("AfterPassage",afterPassage),("BeforeVerse",beforeVerse),("AfterVerse",afterVerse)]
        let templatesNode=section("templates",templates.map { name,template in
            let original=sourceXML?.child(named:"templates")?.children(named:"template").first{$0.attributes["name"]==name}
            let known=Set(["Bold","Italic","Underline","Superscript","Subscript"])
            let retained=original?.content.filter{item in
                guard case let .element(node)=item else { return true }
                return node.name != "pattern" && !(node.name=="format" && known.contains(node.attributes["name"] ?? ""))
            } ?? []
            let fields:[(String,Bool)]=[("Bold",template.bold),("Italic",template.italic),("Underline",template.underline),("Superscript",template.superscript),("Subscript",template.subscriptText)]
            return XMLNode(name:"template",attributes:["name":name],content:retained+[.element(value("pattern",template.pattern,attributes:["xml:space":"preserve"]))]+fields.map{.element(value("format",$0.1 ? "true":"false",attributes:["name":$0.0]))})
        })
        func rendering(_ rendering:BibleCopyLanguageRendering,hebrew:Bool) -> String {
            switch rendering { case .unicode:"unicode";case .transliterated:hebrew ? "Hebrew-LatinLogos":"Greek-LatinSBL";case .hebraicaII:"HebraicaII";case .michiganClaremont:"Michigan-Claremont" }
        }
        let letters=hebrewLetters == .full ? "full-text":hebrewLetters == .consonantsAndVowels ? "no-cantillation":"consonants-only"
        let languages=section("languages",[("el",rendering(greek,hebrew:false)),("he",rendering(hebrew,hebrew:true)),("he_letters",letters)].map{value("language",$0.1,attributes:["name":$0.0])})
        let replacing=Set(["options","templates","languages"])
        let retained=sourceXML?.content.filter{item in if case let .element(node)=item { return !replacing.contains(node.name) };return true} ?? []
        var attributes=sourceXML?.attributes ?? [:];attributes["name"]=name;attributes["guid"]="{\(id.uuidString)}";attributes["creator"]="Libron-X";attributes.removeValue(forKey:"owner")
        let node=XMLNode(name:"lbx-copy-bible-verses-style",attributes:attributes,content:retained+[optionsNode,templatesNode,languages].map{.element($0)})
        let bytes=Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"+serialize(node)+"\n").utf8)
        _=try MetadataXMLReader.parse(bytes);return bytes
    }
    private func serialize(_ node:XMLNode) -> String {
        func escape(_ text:String,attribute:Bool = false) -> String {
            let value=text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;")
            return attribute ? value.replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"\n",with:"&#10;").replacingOccurrences(of:"\r",with:"&#13;").replacingOccurrences(of:"\t",with:"&#9;"):value
        }
        let attrs=node.attributes.keys.sorted().map{" \($0)=\"\(escape(node.attributes[$0]!,attribute:true))\""}.joined()
        let content=node.content.map { item -> String in
            switch item {
            case let .text(text):escape(text)
            case let .cdata(text):"<![CDATA["+text.replacingOccurrences(of:"]]>",with:"]]]]><![CDATA[>")+"]]>"
            case let .comment(text):"<!--"+text+"-->"
            case let .element(child):serialize(child)
            }
        }.joined()
        return "<\(node.name)\(attrs)>\(content)</\(node.name)>"
    }
}
