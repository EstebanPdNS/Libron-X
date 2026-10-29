import Foundation
import LibronixCore

/// Matches WorkspaceDocumentsView's current editor projection. Source XML and
/// rich-edit provenance are never rewritten or treated as visible editor text.
enum PersonalReferenceProjection {
    static func body(_ note: StudyNote) -> (text: String, links: [BibleReferenceSourceLink], issue: String?) {
        let issue: String?
        if let data = note.editedRTF {
            if let projection = try? NoteRichTextCodec.projection(data) { return (projection.text, projection.links, nil) }
            issue = "no se pudo abrir el RTF guardado; se busca la vista de solo lectura del original."
        } else {
            issue = NoteRichTextCodec.hasUnsupportedHTMLObjects(note)
                ? "el HTML original conserva objetos no compatibles; se busca el texto visible." : nil
        }
        guard note.sourceContentType == "text/html" else { return (note.sourceBody, [], issue) }
        var text = "", links: [BibleReferenceSourceLink] = [], offset = 0
        for span in NoteHTMLProjection.spans(note.sourceBody) {
            let length = span.text.utf16.count
            if let target = span.reference, !span.text.isEmpty {
                let range = SearchTextRange(location: offset, length: length)
                // Adjacent formatting spans of the same reference remain one
                // clickable source citation instead of repeated results.
                if let last = links.last, last.target == target, last.range.upperBound == range.location {
                    links[links.count - 1] = .init(range: .init(location: last.range.location,
                        length: last.range.length + range.length), target: target)
                } else { links.append(.init(range: range, target: target)) }
            }
            text += span.text
            offset += length
        }
        return (text, links, issue)
    }
    static func anchor(_ note: StudyNote) -> String? {
        note.effectiveAnchor.location?.reference ?? note.effectiveAnchor.legacyAttributes["reference"]
    }
    static func source(_ document: StudyDocument) throws -> BibleReferencePersonalSource {
        try Task.checkCancellation(); try document.validate()
        var fields: [BibleReferencePersonalField] = [.init(kind: .documentTitle, text: document.title)]
        if let metadata = document.sermon, !metadata.passages.isEmpty {
            fields.append(.init(kind: .sermonPassages, text: metadata.passages.joined(separator: "\n")))
        }
        var warnings: [String] = []
        for note in document.notes {
            try Task.checkCancellation()
            fields.append(.init(entryID: note.id, kind: .noteTitle, text: note.title))
            let projection = body(note)
            fields.append(.init(entryID: note.id, kind: .noteBody, text: projection.text, links: projection.links))
            if let reference = anchor(note), !reference.isEmpty {
                fields.append(.init(entryID: note.id, kind: .noteAnchor, text: reference))
            }
            if let issue = projection.issue { warnings.append(note.title + ": " + issue) }
        }
        for verse in document.verses {
            try Task.checkCancellation()
            fields.append(.init(entryID: verse.id, kind: .verseEntry, text: verse.reference))
        }
        return .init(documentID: document.id, title: document.title, fields: fields,
                     warnings: warnings, projectionComplete: warnings.isEmpty)
    }
    static func validate(_ destination: BibleReferencePersonalDestination,
                         documents: [StudyDocument]) throws -> BibleReferencePersonalField {
        guard let document = documents.first(where: { $0.id == destination.documentID }),
              let field = try field(destination, in: document),
              LibrarySearchService.textFingerprint(field.text) == destination.textSHA256,
              try field.projectionFingerprint() == destination.projectionSHA256,
              destination.range.location >= 0, destination.range.length > 0,
              destination.range.location <= field.text.utf16.count,
              destination.range.length <= field.text.utf16.count - destination.range.location,
              Range(destination.range.nsRange, in: field.text) != nil else {
            throw PersonalStateError.invalid("El resultado cambió o ya no está disponible. Repite la búsqueda antes de abrirlo.")
        }
        return field
    }
    private static func field(_ destination: BibleReferencePersonalDestination,
                              in document: StudyDocument) throws -> BibleReferencePersonalField? {
        try document.validate()
        if destination.field == .documentTitle {
            return destination.entryID == nil ? .init(kind: .documentTitle, text: document.title) : nil
        }
        if destination.field == .sermonPassages {
            guard destination.entryID == nil, let metadata = document.sermon else { return nil }
            return .init(kind: .sermonPassages, text: metadata.passages.joined(separator: "\n"))
        }
        if destination.field == .verseEntry {
            return document.verses.first { $0.id == destination.entryID }.map {
                .init(entryID: $0.id, kind: .verseEntry, text: $0.reference)
            }
        }
        guard let note = document.notes.first(where: { $0.id == destination.entryID }) else { return nil }
        switch destination.field {
        case .noteTitle: return .init(entryID: note.id, kind: .noteTitle, text: note.title)
        case .noteBody:
            let projection = body(note)
            return .init(entryID: note.id, kind: .noteBody, text: projection.text, links: projection.links)
        case .noteAnchor: return anchor(note).map { .init(entryID: note.id, kind: .noteAnchor, text: $0) }
        default: return nil
        }
    }
}
