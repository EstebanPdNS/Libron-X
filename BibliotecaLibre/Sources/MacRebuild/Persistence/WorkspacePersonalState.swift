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
    @discardableResult func create(_ kind: StudyDocumentKind) -> UUID {
        let document = StudyDocument(title: kind == .notebook ? "Mis notas" : "Lista de versículos", kind: kind)
        documents.append(document); selectedDocumentID = document.id; scheduleSave(); return document.id
    }
}
