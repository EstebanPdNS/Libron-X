import Foundation

public enum StudyNoteSort: String, CaseIterable, Sendable { case title, reference, modified }

public struct StudyNoteOutlineEntry: Identifiable, Sendable {
    public let note: StudyNote
    public let depth: Int
    public var id: UUID { note.id }
}

/// Operations work on copies, validate the resulting documents, and preserve
/// note identities, source markup, native RTF, annotations and imported XML.
public enum StudyNoteOrganization {
    public static func outline(_ notes: [StudyNote]) throws -> [StudyNoteOutlineEntry] {
        guard notes.count <= 10_000, Set(notes.map(\.id)).count == notes.count else { throw invalidHierarchy() }
        let ids = Set(notes.map(\.id))
        guard notes.allSatisfy({ $0.parentID == nil || ($0.parentID != $0.id && ids.contains($0.parentID!)) }) else { throw invalidHierarchy() }
        let children = Dictionary(grouping: notes, by: \.parentID)
        var stack = (children[nil] ?? []).reversed().map { ($0, 0) }
        var result: [StudyNoteOutlineEntry] = []
        while let (note, depth) = stack.popLast() {
            guard depth <= 64 else { throw invalidHierarchy() }
            result.append(.init(note: note, depth: depth))
            for child in (children[note.id] ?? []).reversed() { stack.append((child, depth + 1)) }
        }
        guard result.count == notes.count else { throw invalidHierarchy() }
        return result
    }

    public static func subtree(_ ids: Set<UUID>, in notes: [StudyNote]) throws -> Set<UUID> {
        let entries = try outline(notes)
        guard !ids.isEmpty, ids.isSubset(of: Set(notes.map(\.id))) else {
            throw PersonalStateError.invalid("Selecciona notas que sigan disponibles.")
        }
        var result = ids
        for entry in entries where entry.note.parentID.map(result.contains) == true { result.insert(entry.id) }
        return result
    }

    public static func moving(_ ids: Set<UUID>, from sourceID: UUID, to destinationID: UUID,
                              parentID: UUID? = nil, beforeID: UUID? = nil, documents: [StudyDocument]) throws -> [StudyDocument] {
        guard let source = documents.firstIndex(where: { $0.id == sourceID && $0.kind == .notebook }),
              let destination = documents.firstIndex(where: { $0.id == destinationID && $0.kind == .notebook }) else {
            throw PersonalStateError.invalid("El cuaderno de origen o destino no está disponible.")
        }
        try documents[source].validate(); try documents[destination].validate()
        let selected = try subtree(ids, in: documents[source].notes)
        let targetNotes = documents[destination].notes
        guard parentID.map({ parent in !selected.contains(parent) && targetNotes.contains(where: { $0.id == parent }) }) ?? true,
              beforeID.map({ before in !selected.contains(before) && targetNotes.contains(where: { $0.id == before && $0.parentID == parentID }) }) ?? true else {
            throw invalidHierarchy()
        }
        var moved = try outline(documents[source].notes).map(\.note).filter { selected.contains($0.id) }
        for index in moved.indices {
            if moved[index].parentID.map(selected.contains) != true { moved[index].parentID = parentID }
            if sourceID != destinationID, moved[index].origin == nil {
                moved[index].origin = .init(document: documents[source], note: moved[index])
            }
        }
        var result = documents
        result[source].schemaVersion = 2; result[destination].schemaVersion = 2
        result[source].notes.removeAll { selected.contains($0.id) }
        let insertion = beforeID.flatMap { before in result[destination].notes.firstIndex(where: { $0.id == before }) } ?? result[destination].notes.endIndex
        result[destination].notes.insert(contentsOf: moved, at: insertion)
        try result[source].validate(); try result[destination].validate()
        return result
    }

    public static func duplicating(_ ids: Set<UUID>, in document: StudyDocument, titleSuffix: String) throws -> StudyDocument {
        try document.validate()
        let selected = try subtree(ids, in: document.notes)
        let originals = try outline(document.notes).map(\.note).filter { selected.contains($0.id) }
        let replacements = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
        var result = document
        result.schemaVersion = 2
        for original in originals {
            var copy = original
            copy.id = replacements[original.id]!
            copy.parentID = original.parentID.map { replacements[$0] ?? $0 }
            copy.origin = original.origin ?? .init(document: document, note: original)
            copy.title += " (" + titleSuffix + ")"
            copy.modifiedUTC = ISO8601DateFormatter().string(from: Date())
            result.notes.append(copy)
        }
        try result.validate(); return result
    }

    /// Removing a parent promotes surviving children instead of silently
    /// deleting unselected notes or leaving dangling parent identifiers.
    public static func deleting(_ ids: Set<UUID>, from document: StudyDocument) throws -> StudyDocument {
        try document.validate()
        let parents = Dictionary(uniqueKeysWithValues: document.notes.map { ($0.id, $0.parentID) })
        var result = document
        if document.notes.contains(where: { $0.parentID != nil }) { result.schemaVersion = 2 }
        result.notes.removeAll { ids.contains($0.id) }
        for index in result.notes.indices {
            var parent = result.notes[index].parentID
            while let current = parent, ids.contains(current) { parent = parents[current] ?? nil }
            result.notes[index].parentID = parent
        }
        try result.validate(); return result
    }

    public static func sorting(_ document: StudyDocument, by order: StudyNoteSort) throws -> StudyDocument {
        try document.validate()
        let positions = Dictionary(uniqueKeysWithValues: document.notes.enumerated().map { ($0.element.id, $0.offset) })
        let dates = Dictionary(uniqueKeysWithValues: document.notes.map { ($0.id, date($0.modifiedUTC)) })
        let references = Dictionary(uniqueKeysWithValues: document.notes.map { ($0.id, address($0)) })
        var result = document
        result.notes.sort { a, b in
            switch order {
            case .title:
                let comparison = a.title.localizedStandardCompare(b.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .modified:
                if dates[a.id] != dates[b.id] { return dates[a.id]! > dates[b.id]! }
            case .reference:
                let a = references[a.id] ?? nil, b = references[b.id] ?? nil
                if a != b {
                    if let a, let b { return a < b }
                    return a != nil
                }
            }
            return positions[a.id]! < positions[b.id]!
        }
        result.notes = try outline(result.notes).map(\.note)
        try result.validate(); return result
    }

    private static func address(_ note: StudyNote) -> BibleReferenceAddress? {
        guard let reference = note.effectiveAnchor.location?.reference ?? note.effectiveAnchor.legacyAttributes["reference"] else { return nil }
        if let parsed = LegacyPassageQuery.sourceReference(reference) {
            return .init(book: parsed.sourceBookKey, chapter: parsed.chapter, verse: parsed.verse)
        }
        return (try? BibleReferenceQuery.parse(reference))?.citations.flatMap(\.spans).map(\.lower).min()
    }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) ?? .distantPast
    }

    private static func invalidHierarchy() -> PersonalStateError {
        .invalid("La jerarquía de notas contiene un destino ausente, un ciclo o demasiados niveles.")
    }
}
