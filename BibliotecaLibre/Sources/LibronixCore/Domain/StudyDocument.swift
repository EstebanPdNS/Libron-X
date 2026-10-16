import Foundation

public enum StudyDocumentKind: String, Codable, Sendable { case notebook, verseList }
public enum StudyNoteAnchorKind: String, Codable, Sendable { case general, nativeSelection, nativeReference, legacySelection, legacyReference }

public struct StudyNoteAnchor: Codable, Equatable, Sendable {
    public var kind: StudyNoteAnchorKind
    public var location: ReaderLocation?
    public var selection: SearchTextRange?
    public var legacyAttributes: [String: String]
    public init(kind: StudyNoteAnchorKind = .general, location: ReaderLocation? = nil, selection: SearchTextRange? = nil,
                legacyAttributes: [String: String] = [:]) {
        self.kind = kind; self.location = location; self.selection = selection; self.legacyAttributes = legacyAttributes
    }
}

public struct StudyNote: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var sourceAttributes: [String: String] = [:]
    public var sourceContentType = "text/html"
    public var sourceBody = ""
    public var editedRTF: Data?
    public var anchor: StudyNoteAnchor
    public var resolvedAnchor: StudyNoteAnchor?
    public var effectiveAnchor: StudyNoteAnchor { resolvedAnchor ?? anchor }
    public var modifiedUTC: String
    public init(title: String = "Nueva nota", anchor: StudyNoteAnchor = StudyNoteAnchor()) {
        self.title = title; self.anchor = anchor; self.modifiedUTC = ISO8601DateFormatter().string(from: Date())
    }
}

public struct StudyVerseEntry: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var reference: String
    public var location: ReaderLocation?
    public init(reference: String, location: ReaderLocation? = nil) { self.reference = reference; self.location = location }
}

/// The imported XML and original attributes remain immutable provenance data.
/// Native edits use a separate representation and never rewrite the original.
public struct StudyDocument: Identifiable, Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var title: String
    public var kind: StudyDocumentKind
    public var notes: [StudyNote] = []
    public var verses: [StudyVerseEntry] = []
    public var referenceAttributes: [String: String] = [:]
    public var sourceXML: XMLNode?
    public var sourceSHA256: String?
    public var presentation: String
    public init(title: String, kind: StudyDocumentKind) {
        self.title = title; self.kind = kind; presentation = kind == .verseList ? "ReferencesOnly" : "Notes"
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 4_096,
              notes.count <= 10_000, verses.count <= 100_000,
              Set(notes.map(\.id)).count == notes.count, Set(verses.map(\.id)).count == verses.count,
              (kind == .notebook ? verses.isEmpty : notes.isEmpty) else {
            throw PersonalStateError.invalid("El documento tiene un nombre, tipo o número de entradas incompatible.")
        }
        for note in notes {
            guard note.title.utf8.count <= 4_096, note.sourceBody.utf8.count <= MetadataXMLReader.maximumFileBytes,
                  (note.editedRTF?.count ?? 0) <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
            if [.nativeSelection, .nativeReference].contains(note.anchor.kind) {
                guard let location = note.anchor.location, location.sectionOrdinal >= 0, location.textFingerprint != nil else {
                    throw PersonalStateError.invalid("La nota no conserva la identidad comprobada de su texto fuente.")
                }
            }
            if note.anchor.kind == .nativeSelection {
                guard let range = note.anchor.selection, range.location >= 0, range.length > 0,
                      range.location <= Int.max - range.length else { throw PersonalStateError.invalid("La selección de la nota no es válida.") }
            }
            if let derived = note.resolvedAnchor {
                guard derived.kind == .nativeSelection, let location = derived.location, location.sectionOrdinal >= 0,
                      location.textFingerprint != nil, let selection = derived.selection, selection.location >= 0,
                      selection.length >= 0, selection.location <= Int.max - selection.length else {
                    throw PersonalStateError.invalid("La posición derivada de una nota no tiene identidad o coordenadas válidas.")
                }
            }
        }
        for verse in verses {
            guard !verse.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  verse.reference.utf8.count <= 4_096, verse.location.map({ $0.sectionOrdinal >= 0 }) ?? true else {
                throw PersonalStateError.invalid("La lista contiene una referencia vacía o un destino inválido.")
            }
        }
    }
    public static func importingLegacyXML(_ data: Data, sourceSHA256: String? = nil) throws -> StudyDocument {
        let root = try MetadataXMLReader.parse(data)
        let kind: StudyDocumentKind
        switch root.name {
        case "lbx-annotations": kind = .notebook
        case "lbx-verse-list": kind = .verseList
        default: throw MetadataReadError.unsupportedDocument(root.name)
        }
        var result = StudyDocument(title: root.attributes["name"] ?? "Documento importado", kind: kind)
        result.sourceXML = root; result.sourceSHA256 = sourceSHA256
        if kind == .notebook {
            for annotation in root.children(named: "annotation") {
                var note = StudyNote(title: annotation.child(named: "title")?.text ?? "Nota importada")
                note.sourceAttributes = annotation.attributes
                note.sourceContentType = annotation.child(named: "content")?.attributes["type"] ?? "text/plain"
                note.sourceBody = annotation.child(named: "content")?.text ?? ""
                note.modifiedUTC = annotation.attributes["modified"] ?? ""
                if annotation.attributes["special"] != nil || annotation.attributes["resource-id"] != nil {
                    note.anchor = StudyNoteAnchor(kind: .legacySelection, legacyAttributes: annotation.attributes)
                } else if annotation.attributes["reference"] != nil {
                    note.anchor = StudyNoteAnchor(kind: .legacyReference, legacyAttributes: annotation.attributes)
                }
                result.notes.append(note)
            }
        } else if let refs = root.child(named: "refs") {
            result.referenceAttributes = refs.attributes
            result.presentation = refs.attributes["style"] ?? "ReferencesOnly"
            result.verses = refs.children(named: "ref").map { StudyVerseEntry(reference: $0.text) }
        }
        try result.validate(); return result
    }
}

public struct NoteTextSpan: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    public var reference: String?
    public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, reference: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.underline = underline; self.reference = reference
    }
}

/// An inert projection of note markup. It never invokes a browser, scripts,
/// external fonts, image loaders, or a network-capable HTML renderer.
public enum NoteHTMLProjection {
    public static func spans(_ html: String) -> [NoteTextSpan] {
        guard html.utf8.count <= MetadataXMLReader.maximumFileBytes else { return [] }
        struct Style { var tag: String; var bold: Bool; var italic: Bool; var underline: Bool; var reference: String? }
        var stack: [Style] = [], result: [NoteTextSpan] = [], cursor = html.startIndex, suppressed: String?
        func append(_ text: String) {
            guard !text.isEmpty, suppressed == nil else { return }
            result.append(NoteTextSpan(text: decodeEntities(text), bold: stack.contains(where: \.bold),
                italic: stack.contains(where: \.italic), underline: stack.contains(where: \.underline), reference: stack.last(where: { $0.reference != nil })?.reference))
        }
        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                append(String(html[cursor..<end])); cursor = end; continue
            }
            if html[cursor...].hasPrefix("<!--"), let end = html[cursor...].range(of: "-->") { cursor = end.upperBound; continue }
            var end = html.index(after: cursor), quote: Character?
            while end < html.endIndex {
                let char = html[end]
                if let current = quote { if char == current { quote = nil } }
                else if char == "\"" || char == "'" { quote = char }
                else if char == ">" { break }
                end = html.index(after: end)
            }
            guard end < html.endIndex else { append(String(html[cursor...])); break }
            let token = String(html[html.index(after: cursor)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = html.index(after: end)
            let closing = token.hasPrefix("/"), raw = closing ? String(token.dropFirst()) : token
            let tag = String(raw.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
            if ["script", "style"].contains(tag) {
                if closing && suppressed == tag { suppressed = nil }
                else if !closing { suppressed = tag }
                continue
            }
            guard suppressed == nil else { continue }
            if closing {
                if let index = stack.lastIndex(where: { $0.tag == tag }) { stack.removeSubrange(index...) }
                if ["p", "div", "li"].contains(tag), result.last?.text.hasSuffix("\n") != true { append("\n") }
            } else if tag == "br" { append("\n") }
            else if ["p", "div", "li"].contains(tag) {
                if !result.isEmpty && result.last?.text.hasSuffix("\n") != true { append("\n") }
            } else if !["img", "link", "meta", "hr"].contains(tag), stack.count < 128 {
                let attrs = attributes(raw)
                stack.append(Style(tag: tag, bold: ["b", "strong"].contains(tag), italic: ["i", "em"].contains(tag),
                    underline: tag == "u", reference: attrs["lbxrt:xref"]))
            }
        }
        return result
    }
    private static func attributes(_ token: String) -> [String: String] {
        let pattern = #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let text = token as NSString; var result: [String: String] = [:]
        for match in regex.matches(in: token, range: NSRange(location: 0, length: text.length)) {
            let key = text.substring(with: match.range(at: 1)).lowercased()
            let value = (2...4).first { match.range(at: $0).location != NSNotFound }
            if let value { result[key] = decodeEntities(text.substring(with: match.range(at: value))) }
        }
        return result
    }
    private static func decodeEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(?:amp|lt|gt|quot|apos|nbsp|#\d+|#x[0-9a-fA-F]+);"#) else { return text }
        let original = text as NSString, result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let raw = original.substring(with: match.range), code = String(raw.dropFirst().dropLast())
            let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}"]
            var value = named[code]
            if code.hasPrefix("#") {
                let number = code.hasPrefix("#x") ? UInt32(code.dropFirst(2), radix: 16) : UInt32(code.dropFirst())
                if let number, let scalar = UnicodeScalar(number), number != 0 { value = String(scalar) }
            }
            if let value { result.replaceCharacters(in: match.range, with: value) }
        }
        return result as String
    }
}
