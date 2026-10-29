import Foundation

public enum StudyDocumentKind: String, Codable, Sendable {
    case notebook, verseList, sermon
    public var usesNotes: Bool { self != .verseList }
}
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
    public var parentID: UUID?
    public var properties: [String: String]?
    public var origin: StudyNoteOrigin?
    public var effectiveAnchor: StudyNoteAnchor { resolvedAnchor ?? anchor }
    public var modifiedUTC: String
    public init(title: String = "Nueva nota", anchor: StudyNoteAnchor = StudyNoteAnchor()) {
        self.title = title; self.anchor = anchor; self.modifiedUTC = ISO8601DateFormatter().string(from: Date())
    }
}

public struct StudyNoteOrigin: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let noteID: UUID
    public let documentTitle: String
    public let sourceSHA256: String?
    public init(document: StudyDocument, note: StudyNote) {
        documentID = document.id; noteID = note.id; documentTitle = document.title; sourceSHA256 = document.sourceSHA256
    }
}

public struct StudyVerseEntry: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var reference: String
    public var location: ReaderLocation?
    public init(reference: String, location: ReaderLocation? = nil) { self.reference = reference; self.location = location }
}

/// Editing operations preserve entry identities, source metadata and destinations.
public enum StudyVerseOrganization {
    /// An edited reference retains entry identity but cannot retain the old physical destination.
    public static func changeReference(_ original: StudyVerseEntry, to reference: String, in document: inout StudyDocument) throws {
        guard document.kind == .verseList, let index = document.verses.firstIndex(of: original) else {
            throw PersonalStateError.concurrentChange
        }
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096 else { throw BibleSearchRangeError.invalidExpression }
        guard value != original.reference else { return }
        document.verses[index].reference = value; document.verses[index].location = nil
    }
    /// Move one entry by one position. Boundary moves leave the list unchanged.
    public static func move(_ id: UUID, by offset: Int, in document: inout StudyDocument) throws {
        guard document.kind == .verseList, [-1, 1].contains(offset),
              let index = document.verses.firstIndex(where: { $0.id == id }) else {
            throw PersonalStateError.invalid("No se puede mover la referencia seleccionada.")
        }
        let destination = index + offset
        guard document.verses.indices.contains(destination) else { return }
        document.verses.swapAt(index, destination)
    }

    /// Sort only when every entry has one unambiguous, recognized starting
    /// address. Never silently move an unknown entry or convert versifications.
    public static func sortCanonically(_ document: inout StudyDocument) throws {
        guard document.kind == .verseList else {
            throw PersonalStateError.invalid("El documento no es una lista de versículos.")
        }
        let keyed = try document.verses.enumerated().map { index, entry in
            let query = try BibleReferenceQuery.parse(entry.reference)
            guard query.citations.count == 1, query.citations[0].spans.count == 1,
                  let span = query.citations[0].spans.first else {
                throw PersonalStateError.invalid("Una referencia no tiene un orden bíblico inequívoco.")
            }
            return (index: index, entry: entry, address: span.lower)
        }
        document.verses = keyed.sorted { lhs, rhs in
            lhs.address == rhs.address ? lhs.index < rhs.index : lhs.address < rhs.address
        }.map(\.entry)
    }
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
    public var verseListEdition: StudyVerseListEdition?
    public var sermon: SermonMetadata?
    public init(title: String, kind: StudyDocumentKind) {
        self.title = title; self.kind = kind; presentation = kind == .verseList ? "ReferencesOnly" : "Notes"
        if kind == .sermon { schemaVersion = 3; sermon = SermonMetadata() }
    }
    public func validate() throws {
        guard (1...4).contains(schemaVersion) else { throw PersonalStateError.futureVersion }
        guard kind == .sermon ? (schemaVersion == 3 && sermon != nil) : sermon == nil else {
            throw PersonalStateError.invalid("El tipo y los datos del sermón no coinciden con la versión del documento.")
        }
        guard verseListEdition == nil || (kind == .verseList && schemaVersion >= 4) else {
            throw PersonalStateError.invalid("La edición de la lista requiere la versión 4 de un documento de versículos.")
        }
        try verseListEdition?.validate()
        try sermon?.validate()
        // Version 2 prevents older applications from loading and then silently
        // dropping hierarchy, properties or move/copy provenance on save.
        guard schemaVersion >= 2 || notes.allSatisfy({ $0.parentID == nil && $0.properties == nil && $0.origin == nil }) else {
            throw PersonalStateError.invalid("La organización de notas requiere la versión 2 del documento.")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 4_096,
              notes.count <= 10_000, verses.count <= 100_000,
              Set(notes.map(\.id)).count == notes.count, Set(verses.map(\.id)).count == verses.count,
              (kind.usesNotes ? verses.isEmpty : notes.isEmpty) else {
            throw PersonalStateError.invalid("El documento tiene un nombre, tipo o número de entradas incompatible.")
        }
        for note in notes {
            guard note.title.utf8.count <= 4_096, note.sourceBody.utf8.count <= MetadataXMLReader.maximumFileBytes,
                  (note.editedRTF?.count ?? 0) <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
            if let properties = note.properties {
                guard properties.count <= 64, properties.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.utf8.count <= 4_096 }) else { throw PersonalStateError.tooLarge }
            }
            if let origin = note.origin {
                guard origin.documentTitle.utf8.count <= 4_096, (origin.sourceSHA256?.utf8.count ?? 0) <= 128 else { throw PersonalStateError.tooLarge }
            }
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
        _ = try StudyNoteOrganization.outline(notes)
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
    public var hyperlink: String?
    public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, reference: String? = nil, hyperlink: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.underline = underline; self.reference = reference; self.hyperlink = hyperlink
    }
}

/// An inert projection of note markup. It never invokes a browser, scripts,
/// external fonts, image loaders, or a network-capable HTML renderer.
public enum NoteHTMLProjection {
    public static func spans(_ html: String) -> [NoteTextSpan] {
        guard html.utf8.count <= MetadataXMLReader.maximumFileBytes else { return [] }
        struct Style { var tag: String; var bold: Bool; var italic: Bool; var underline: Bool; var reference: String?; var hyperlink: String? }
        var stack: [Style] = [], result: [NoteTextSpan] = [], cursor = html.startIndex, suppressed: String?
        var lists: [(tag: String, next: Int)] = []
        func append(_ text: String) {
            guard !text.isEmpty, suppressed == nil else { return }
            result.append(NoteTextSpan(text: decodeEntities(text), bold: stack.contains(where: \.bold),
                italic: stack.contains(where: \.italic), underline: stack.contains(where: \.underline), reference: stack.last(where: { $0.reference != nil })?.reference,
                hyperlink: stack.last(where: { $0.hyperlink != nil })?.hyperlink))
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
                if ["ul", "ol"].contains(tag), let index = lists.lastIndex(where: { $0.tag == tag }) { lists.removeSubrange(index...) }
                if let index = stack.lastIndex(where: { $0.tag == tag }) { stack.removeSubrange(index...) }
                if ["p", "div", "li"].contains(tag), result.last?.text.hasSuffix("\n") != true { append("\n") }
            } else if tag == "br" { append("\n") }
            else if ["ul", "ol"].contains(tag), lists.count < 32 {
                let start = Int(attributes(raw)["start"] ?? "1") ?? 1
                lists.append((tag, max(1, min(start, 1_000_000))))
            }
            else if ["p", "div", "li"].contains(tag) {
                if !result.isEmpty && result.last?.text.hasSuffix("\n") != true { append("\n") }
                if tag == "li", let list = lists.last {
                    append(String(repeating: "  ", count: lists.count - 1) + (list.tag == "ol" ? "\(list.next). " : "• "))
                    lists[lists.count - 1].next += 1
                }
            } else if !["img", "link", "meta", "hr"].contains(tag), stack.count < 128 {
                let attrs = attributes(raw)
                stack.append(Style(tag: tag, bold: ["b", "strong"].contains(tag), italic: ["i", "em"].contains(tag),
                    underline: tag == "u", reference: attrs["lbxrt:xref"], hyperlink: tag == "a" ? attrs["href"] : nil))
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
