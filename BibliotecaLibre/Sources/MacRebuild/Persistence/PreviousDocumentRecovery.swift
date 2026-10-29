import Foundation
import LibronixCore

/// Reads the already-retained predecessor without altering it. Recovery is a
/// new document, so neither the current document nor its notes are overwritten.
enum PreviousDocumentRecovery {
    static func read(from personalURL: URL) throws -> [StudyDocument] {
        let prior = PersonalStateFile<WorkspacePersonalSnapshot>(url: personalURL.appendingPathExtension("previous"))
        guard let snapshot = try prior.load() else { return [] }
        try snapshot.validate()
        return snapshot.documents
    }

    /// Preserve the recovery source before the normal save rotates `.previous`.
    /// The archive also survives an unsuccessful or interrupted save.
    static func archive(_ original: StudyDocument, from personalURL: URL) throws {
        let previous = personalURL.appendingPathExtension("previous")
        let size = try previous.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        let data = try Data(contentsOf: previous)
        guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        let snapshot = try JSONDecoder().decode(WorkspacePersonalSnapshot.self, from: data)
        try snapshot.validate()
        guard snapshot.documents.contains(original) else { throw PersonalStateError.concurrentChange }
        let directory = personalURL.deletingLastPathComponent().appendingPathComponent("personal-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("\(UUID().uuidString).json")
        try data.write(to: destination, options: .atomic)
    }

    static func copy(_ original: StudyDocument, title: String) throws -> StudyDocument {
        try original.validate()
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PersonalStateError.invalid("El nombre del documento no puede estar vacío.") }
        var result = original
        result.id = UUID(); result.title = name
        if original.kind == .notebook {
            let ids = Dictionary(uniqueKeysWithValues: original.notes.map { ($0.id, UUID()) })
            result.schemaVersion = 2
            for index in result.notes.indices {
                let note = original.notes[index]
                result.notes[index].id = ids[note.id]!
                result.notes[index].parentID = note.parentID.flatMap { ids[$0] }
                result.notes[index].origin = note.origin ?? StudyNoteOrigin(document: original, note: note)
            }
        } else {
            for index in result.verses.indices { result.verses[index].id = UUID() }
        }
        try result.validate()
        return result
    }
}
