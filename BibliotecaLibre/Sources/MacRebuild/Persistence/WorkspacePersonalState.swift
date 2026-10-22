import Foundation
import LibronixCore
import Observation

struct WorkspacePersonalSnapshot: Codable {
    var schemaVersion = 1
    var favorites = FavoritesDocument()
    var highlights: [ReaderHighlight] = []
    var documents: [StudyDocument] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        try favorites.validate()
        guard documents.count <= 100, highlights.count <= 100_000,
              Set(documents.map(\.id)).count == documents.count,
              highlights.allSatisfy({ $0.ordinal >= 0 && $0.range.location >= 0 && $0.range.length > 0 &&
                  $0.range.length < 10_000_000 && $0.range.location <= Int.max - $0.range.length &&
                  ["yellow", "green", "blue", "pink"].contains($0.color) }) else { throw PersonalStateError.invalid("Los datos personales contienen entradas incompatibles.") }
        for document in documents { try document.validate() }
    }
}

@MainActor @Observable final class WorkspacePersonalState {
    var favorites = FavoritesDocument()
    var highlights: [ReaderHighlight] = []
    var documents: [StudyDocument] = []
    var selectedDocumentID: UUID?
    var loadError: String?
    @ObservationIgnored private let file: PersonalStateFile<WorkspacePersonalSnapshot>
    @ObservationIgnored private var canSave = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    init(url: URL? = nil) {
        let path = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/personal.json")
        file = PersonalStateFile(url: path)
        do {
            if let saved = try file.load() {
                try saved.validate(); favorites = saved.favorites; highlights = saved.highlights; documents = saved.documents
            }
            canSave = true; selectedDocumentID = documents.first?.id
        } catch { loadError = error.localizedDescription }
    }
    func save() throws {
        saveTask?.cancel()
        guard canSave else { throw PersonalStateError.invalid(loadError ?? "No se pudo abrir el archivo personal; se conservaron sus datos.") }
        let snapshot = WorkspacePersonalSnapshot(favorites: favorites, highlights: highlights, documents: documents)
        try snapshot.validate(); try file.save(snapshot); loadError = nil
    }
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)); try self?.save() }
            catch is CancellationError {} catch { self?.loadError = error.localizedDescription }
        }
    }
    func renameNote(_ id: UUID, in documentID: UUID, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let document = documents.firstIndex(where: { $0.id == documentID }),
              let note = documents[document].notes.firstIndex(where: { $0.id == id }) else { return }
        let previous = documents[document].notes[note]
        documents[document].notes[note].title = title
        documents[document].notes[note].modifiedUTC = ISO8601DateFormatter().string(from: Date())
        do { try save() }
        catch { documents[document].notes[note] = previous; throw error }
    }
    /// The caller must obtain confirmation before invoking this mutation.
    func deleteNotes(_ ids: Set<UUID>, in documentID: UUID) throws {
        guard !ids.isEmpty, let document = documents.firstIndex(where: { $0.id == documentID }) else { return }
        let previous = documents[document].notes
        guard previous.contains(where: { ids.contains($0.id) }) else { return }
        documents[document].notes.removeAll { ids.contains($0.id) }
        do { try save() }
        catch { documents[document].notes = previous; throw error }
    }
    @discardableResult func create(_ kind: StudyDocumentKind) -> UUID {
        let document = StudyDocument(title: kind == .notebook ? "Mis notas" : "Lista de versículos", kind: kind)
        documents.append(document); selectedDocumentID = document.id; scheduleSave(); return document.id
    }
}
