import Foundation
import LibronixCore
import Observation

struct WorkspaceSavedQuery: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var configuration: WorkspaceSearchConfiguration
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 1024, !title.contains("\0") else {
            throw PersonalStateError.invalid("La consulta guardada necesita un nombre válido.")
        }
        try configuration.validate()
    }
}
struct WorkspaceSavedQueriesSnapshot: Codable, Equatable {
    var schemaVersion = 1
    var queries: [WorkspaceSavedQuery] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard queries.count <= 1000, Set(queries.map(\.id)).count == queries.count else { throw PersonalStateError.tooLarge }
        for query in queries { try query.validate() }
    }
}
struct WorkspaceSavedQueryDocument: Codable {
    let kind: String
    let schemaVersion: Int
    let query: WorkspaceSavedQuery
    init(query: WorkspaceSavedQuery) { kind = "libronx-search"; schemaVersion = 1; self.query = query }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        return data
    }
    static func read(_ data: Data) throws -> Self {
        guard data.count <= MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(); return result
    }
    func validate() throws {
        guard kind == "libronx-search" else { throw PersonalStateError.invalid("El archivo no es una consulta guardada.") }
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        try query.validate()
    }
}
@MainActor @Observable final class WorkspaceSavedQueries {
    private(set) var queries: [WorkspaceSavedQuery] = []
    private(set) var loadError: String?
    @ObservationIgnored private let file: PersonalStateFile<WorkspaceSavedQueriesSnapshot>
    @ObservationIgnored private var writable = false
    init(url: URL) {
        file = PersonalStateFile(url: url)
        do {
            if let snapshot = try file.load() { try snapshot.validate(); queries = snapshot.queries }
            writable = true
        } catch { loadError = error.localizedDescription }
    }
    func save(original: WorkspaceSavedQuery?, replacement: WorkspaceSavedQuery) throws {
        try edit { values in
            if let original {
                guard original.id == replacement.id,
                      let index = values.firstIndex(where: { $0.id == original.id }), values[index] == original
                else { throw PersonalStateError.concurrentChange }
                values[index] = replacement
            } else { values.append(replacement) }
        }
    }
    func remove(_ original: WorkspaceSavedQuery) throws {
        try edit { values in
            guard let index = values.firstIndex(where: { $0.id == original.id }), values[index] == original
            else { throw PersonalStateError.concurrentChange }
            values.remove(at: index)
        }
    }
    private func edit(_ change: (inout [WorkspaceSavedQuery]) throws -> Void) throws {
        guard writable else { throw PersonalStateError.invalid(loadError ?? "No se pudieron abrir las consultas guardadas.") }
        var next = queries; try change(&next)
        let snapshot = WorkspaceSavedQueriesSnapshot(queries: next)
        try snapshot.validate(); guard next != queries else { return }
        try file.save(snapshot); queries = next
    }
}
