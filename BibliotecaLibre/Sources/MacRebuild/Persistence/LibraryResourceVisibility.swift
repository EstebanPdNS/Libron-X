import Foundation
import Observation
import LibronixCore

/// An exclusion belongs to a physical path, format and observed edition ID.
/// Titles alone never hide another translation or format.
struct HiddenLibraryResource: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var format: ResourceFormat
    var legacyIdentifier: String?
    init(_ resource: LibraryResource) {
        id = resource.id; title = resource.title
        format = resource.format; legacyIdentifier = resource.legacyIdentifier
    }
    func matches(_ resource: LibraryResource) -> Bool {
        id == resource.id && format == resource.format && legacyIdentifier == resource.legacyIdentifier
    }
}

struct LibraryVisibilitySnapshot: Codable {
    var schemaVersion = 1
    var hidden: [HiddenLibraryResource] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard hidden.count <= 50_000, Set(hidden.map(\.id)).count == hidden.count,
              hidden.allSatisfy({ $0.id.hasPrefix("/") && !$0.id.contains("\0") &&
                  $0.id.utf8.count <= 16_384 && $0.title.utf8.count <= 4_096 &&
                  URL(fileURLWithPath: $0.id).standardizedFileURL.path == $0.id }) else {
            throw PersonalStateError.invalid("La lista de recursos ocultos contiene entradas incompatibles.")
        }
    }
}

@MainActor @Observable final class LibraryResourceVisibility {
    private(set) var hidden: [HiddenLibraryResource] = []
    private(set) var loadError: String?
    private var byID: [String: HiddenLibraryResource] = [:]
    @ObservationIgnored private let file: PersonalStateFile<LibraryVisibilitySnapshot>
    @ObservationIgnored private var canSave = false
    init(url: URL? = nil) {
        let path = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/hidden-resources.json")
        file = PersonalStateFile(url: path)
        do {
            if let saved = try file.load() {
                try saved.validate(); hidden = saved.hidden
                byID = Dictionary(uniqueKeysWithValues: hidden.map { ($0.id, $0) })
            }
            canSave = true
        } catch { loadError = error.localizedDescription }
    }
    func isHidden(_ resource: LibraryResource) -> Bool { byID[resource.id]?.matches(resource) == true }
    func hide(_ resources: [LibraryResource]) throws {
        var next = Dictionary(uniqueKeysWithValues: hidden.map { ($0.id, $0) })
        for resource in resources { next[resource.id] = HiddenLibraryResource(resource) }
        try commit(next.values.sorted { $0.id < $1.id })
    }
    func restore(_ ids: Set<String>) throws { try commit(hidden.filter { !ids.contains($0.id) }) }
    private func commit(_ next: [HiddenLibraryResource]) throws {
        guard canSave else { throw PersonalStateError.invalid(loadError ?? "No se pudo validar la lista de recursos ocultos.") }
        let snapshot = LibraryVisibilitySnapshot(hidden: next)
        try snapshot.validate(); try file.save(snapshot)
        hidden = next; byID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) }); loadError = nil
    }
}
