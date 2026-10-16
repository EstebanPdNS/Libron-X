import Foundation

public enum BibleCopyParagraphPolicy: String, Codable, CaseIterable, Sendable {
    case perVerse, sourceParagraphs, perPassage
}
public enum BibleCopyLanguageRendering: String, Codable, CaseIterable, Sendable {
    case unicode, transliterated, hebraicaII, michiganClaremont
}
public enum BibleCopyHebrewLetters: String, Codable, CaseIterable, Sendable {
    case full, consonantsAndVowels, consonantsOnly
}
public struct BibleCopyOutputTemplate: Codable, Hashable, Sendable {
    public var pattern: String
    public var bold = false
    public var italic = false
    public var underline = false
    public var superscript = false
    public var subscriptText = false
    public init(_ pattern: String = "") { self.pattern = pattern }
}

/// Owned style fields, separately from source provenance and destination apps.
/// Importing a style parses inert XML; it never evaluates a template as code.
public struct BibleCopyOutputStyle: Identifiable, Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var name: String
    public var preset: String?
    public var characterFormatting = true
    public var paragraphFormatting = true
    public var redLetter = true
    public var citation = true
    public var copyFootnotes = false
    public var bibleTextOnly = true
    public var paragraphs = BibleCopyParagraphPolicy.perVerse
    public var beforePassage = BibleCopyOutputTemplate()
    public var afterPassage = BibleCopyOutputTemplate()
    public var beforeVerse = BibleCopyOutputTemplate("^v ")
    public var afterVerse = BibleCopyOutputTemplate("^n")
    public var greek = BibleCopyLanguageRendering.unicode
    public var hebrew = BibleCopyLanguageRendering.unicode
    public var hebrewLetters = BibleCopyHebrewLetters.full
    public var sourceXML: XMLNode?
    public var sourceSHA256: String?
    public init(name: String = "Nuevo estilo") { self.name = name }
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard greek == .unicode || greek == .transliterated else { throw BibleCopyError.invalidStyle }
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.utf8.count <= 4_096 else {
            throw PersonalStateError.invalid("El estilo necesita un nombre de hasta 4.096 bytes.")
        }
        for template in [beforePassage,afterPassage,beforeVerse,afterVerse] {
            guard template.pattern.utf8.count <= 16_384 else {
                throw PersonalStateError.invalid("La plantilla es demasiado larga.")
            }
            try BibleCopyOutputTemplateExpander.validate(template.pattern)
        }
    }
    public static func importing(_ data: Data, sourceSHA256: String? = nil) throws -> BibleCopyOutputStyle {
        let root = try MetadataXMLReader.parse(data)
        guard root.name == "lbx-copy-bible-verses-style" else { throw MetadataReadError.unsupportedDocument(root.name) }
        var result = BibleCopyOutputStyle(name:root.attributes["name"] ?? "Estilo importado")
        result.sourceXML = root; result.sourceSHA256 = sourceSHA256
        let options = root.child(named:"options")?.children(named:"option") ?? []
        guard Set(options.compactMap{$0.attributes["name"]}).count == options.count else { throw BibleCopyError.invalidStyle }
        var values:[String:Bool] = [:]
        for option in options {
            guard let key = option.attributes["name"], ["true","false"].contains(option.text) else { throw BibleCopyError.invalidStyle }
            values[key] = option.text == "true"
        }
        result.characterFormatting = values["CharacterFormatting"] ?? true
        result.paragraphFormatting = values["ParagraphFormatting"] ?? true
        result.redLetter = values["RedLetter"] ?? true
        result.citation = values["BibliographicCitation"] ?? true
        result.copyFootnotes = values["CopyFootnotes"] ?? false
        result.bibleTextOnly = values["BibleTextOnly"] ?? false
        let templates = root.child(named:"templates")?.children(named:"template") ?? []
        guard Set(templates.compactMap{$0.attributes["name"]}).count == templates.count else { throw BibleCopyError.invalidStyle }
        func template(_ name: String) throws -> BibleCopyOutputTemplate {
            guard let value = templates.first(where:{$0.attributes["name"] == name}) else { return .init() }
            var result = BibleCopyOutputTemplate(value.child(named:"pattern")?.text ?? "")
            let flags = value.children(named:"format")
            guard Set(flags.compactMap{$0.attributes["name"]}).count == flags.count,
                  flags.allSatisfy({ ["", "true", "false"].contains($0.text) }) else { throw BibleCopyError.invalidStyle }
            func enabled(_ key: String) -> Bool { flags.first(where:{$0.attributes["name"] == key})?.text == "true" }
            result.bold = enabled("Bold"); result.italic = enabled("Italic"); result.underline = enabled("Underline")
            result.superscript = enabled("Superscript"); result.subscriptText = enabled("Subscript")
            return result
        }
        result.beforePassage = try template("BeforePassage"); result.afterPassage = try template("AfterPassage")
        result.beforeVerse = try template("BeforeVerse"); result.afterVerse = try template("AfterVerse")
        result.paragraphs = !result.bibleTextOnly || values["BTORemoveParagraphs"] == false ? .sourceParagraphs :
            result.afterVerse.pattern.contains("^n") ? .perVerse : .perPassage
        let languages = root.child(named:"languages")?.children(named:"language") ?? []
        guard Set(languages.compactMap{$0.attributes["name"]}).count == languages.count else { throw BibleCopyError.invalidStyle }
        func language(_ key: String) throws -> BibleCopyLanguageRendering {
            switch languages.first(where:{$0.attributes["name"] == key})?.text ?? "unicode" {
            case "unicode": .unicode
            case "Greek-LatinSBL" where key == "el": .transliterated
            case "Hebrew-LatinLogos" where key == "he": .transliterated
            case "HebraicaII" where key == "he": .hebraicaII
            case "Michigan-Claremont" where key == "he": .michiganClaremont
            default: throw BibleCopyError.unsupportedLanguage
            }
        }
        result.greek = try language("el"); result.hebrew = try language("he")
        switch languages.first(where:{$0.attributes["name"] == "he_letters"})?.text ?? "full" {
        case "full", "full-text": result.hebrewLetters = .full
        case "no-cantillation", "consonants-and-vowels": result.hebrewLetters = .consonantsAndVowels
        case "consonants-only": result.hebrewLetters = .consonantsOnly
        default: throw BibleCopyError.unsupportedLanguage
        }
        try result.validate(); return result
    }
    /// Independent defaults express the observed policies; source files stay
    /// in the user's library and may also be imported through the style editor.
    public static var defaults: [BibleCopyOutputStyle] {
        let names = ["Formato completo","Un versículo por línea","Un versículo por línea con referencia completa","Cita","Párrafos sencillos","Griego y hebreo transliterados"]
        return names.enumerated().map { index,name in
            var result = BibleCopyOutputStyle(name:name); result.preset = String(index)
            result.id = UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",index+1))!
            result.beforePassage = .init("^P (^a)^n")
            switch index {
            case 0: result.bibleTextOnly = false; result.copyFootnotes = true; result.paragraphs = .sourceParagraphs
            case 1: result.characterFormatting = false; result.redLetter = false
            case 2: result.characterFormatting = false; result.redLetter = false; result.beforePassage = .init(); result.beforeVerse = .init("^R ")
            case 3:
                result.characterFormatting = false; result.redLetter = false; result.paragraphs = .perPassage
                result.beforePassage = .init("\"<i>"); result.afterPassage = .init("</i>\" (^P, ^a) "); result.beforeVerse = .init(); result.afterVerse = .init()
            case 4: result.paragraphs = .perPassage; result.beforeVerse.superscript = true; result.afterVerse = .init()
            default: result.characterFormatting = false; result.greek = .transliterated; result.hebrew = .transliterated
            }
            return result
        }
    }
}

public struct BibleCopyOutputTemplateContext: Sendable {
    public var passage: String
    public var shortPassage: String
    public var fullReference: String
    public var shortReference: String
    public var fullBook: String
    public var shortBook: String
    public var chapter: Int
    public var verse: Int
    public var abbreviation: String
    public init(passage:String,fullReference:String,shortReference:String,fullBook:String,shortBook:String,chapter:Int,verse:Int,abbreviation:String,shortPassage:String? = nil) {
        self.passage=passage;self.fullReference=fullReference;self.shortReference=shortReference;self.fullBook=fullBook
        self.shortBook=shortBook;self.chapter=chapter;self.verse=verse;self.abbreviation=abbreviation
        self.shortPassage=shortPassage ?? passage
    }
}
public enum BibleCopyOutputTemplateExpander {
    // All ten codes and sequential replacement order are bound to the
    // inspected configuration script; unknown carets remain literal text.
    public static func validate(_ pattern:String) throws {
        guard pattern.utf8.count <= 16_384 else { throw BibleCopyError.limitExceeded }
    }
    public static func expand(_ pattern:String,context:BibleCopyOutputTemplateContext?) throws -> String {
        try validate(pattern)
        let values:[(String,String)] = [("^a",context?.abbreviation ?? ""),("^B",context?.fullBook ?? ""),
            ("^b",context?.shortBook ?? ""),("^c",context.map{String($0.chapter)} ?? ""),("^n","\n"),
            ("^P",context?.passage ?? ""),("^p",context?.shortPassage ?? ""),("^R",context?.fullReference ?? ""),
            ("^r",context?.shortReference ?? ""),("^v",context.map{String($0.verse)} ?? ""),("^^","^")]
        return values.reduce(pattern) { $0.replacingOccurrences(of:$1.0,with:$1.1) }
    }
}

public enum BibleCopyError: Error, LocalizedError, Equatable, Sendable {
    case invalidPassage, reversedPassage, missingBoundary, incompleteSource, invalidStyle, unknownTemplateToken, unsupportedLanguage, unsupportedContent, limitExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidPassage:"El pasaje necesita un libro, capítulo y versículo, o un rango válido."
        case .reversedPassage:"El final del rango está antes de su inicio."
        case .missingBoundary:"No se ha podido confirmar el límite del pasaje en esta edición."
        case .incompleteSource:"La lectura del pasaje no está completa; no se copia como si lo estuviera."
        case .invalidStyle:"Los campos del estilo no tienen una representación compatible."
        case .unknownTemplateToken:"La plantilla contiene un código especial cuya identidad todavía no está comprobada."
        case .unsupportedLanguage:"Esta representación del idioma todavía no tiene un conversor comprobado."
        case .unsupportedContent:"El pasaje contiene un objeto que todavía no se puede copiar completamente."
        case .limitExceeded:"El pasaje supera los límites de preparación de copia."
        }
    }
}
