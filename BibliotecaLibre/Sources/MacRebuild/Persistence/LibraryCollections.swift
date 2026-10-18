import Foundation
import Observation
import LibronixCore

struct LibraryCollectionMember: Codable, Equatable, Identifiable {
    var resourceID: String
    var title: String
    var format: ResourceFormat
    var legacyIdentifier: String?
    var id: String { resourceID }
    init(_ resource: LibraryResource) {
        resourceID = resource.id; title = resource.title; format = resource.format
        legacyIdentifier = resource.legacyIdentifier
    }
    func resolve(in resources: [LibraryResource]) -> LibraryResource? {
        resources.first { $0.id == resourceID && $0.format == format && $0.legacyIdentifier == legacyIdentifier }
    }
}
struct LibraryCollection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var members: [LibraryCollectionMember] = []
}
struct LibraryCollectionsSnapshot: Codable {
    var schemaVersion = 1
    var sets: [LibraryCollection] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard sets.count <= 256, Set(sets.map(\.id)).count == sets.count else { throw Self.invalid() }
        for set in sets {
            guard !set.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  set.name.utf16.count <= 160, !set.name.contains("\0"), set.members.count <= 8192,
                  Set(set.members.map(\.id)).count == set.members.count,
                  set.members.allSatisfy({ member in
                      member.resourceID.hasPrefix("/") && !member.resourceID.contains("\0") &&
                      member.resourceID.utf8.count <= 16_384 && member.title.utf8.count <= 4096 &&
                      URL(fileURLWithPath: member.resourceID).standardizedFileURL.path == member.resourceID &&
                      (member.legacyIdentifier?.utf8.count ?? 0) <= 1024
                  }) else { throw Self.invalid() }
        }
    }
    private static func invalid() -> PersonalStateError {
        .invalid(AppStrings.text("Las colecciones contienen datos incompatibles.", language: .saved()))
    }
}

/// Manual collections are separate owned state; membership never moves or modifies books.
@MainActor @Observable final class LibraryCollections {
    private(set) var sets: [LibraryCollection] = []
    private(set) var loadError: String?
    @ObservationIgnored private let file: PersonalStateFile<LibraryCollectionsSnapshot>
    @ObservationIgnored private var canSave = false
    init(url: URL? = nil) {
        let path = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/resource-collections.json")
        file = PersonalStateFile(url: path)
        do { try reload() } catch { loadError = error.localizedDescription }
    }
    func reload() throws {
        canSave = false
        do {
            let next = try file.load() ?? .init()
            try next.validate(); sets = next.sets; canSave = true; loadError = nil
        } catch { loadError = error.localizedDescription; throw error }
    }
    @discardableResult func create() throws -> UUID {
        let base = L("Nueva colección")
        var name = base, number = 2
        while sets.contains(where: { $0.name == name }) { name = "\(base) \(number)"; number += 1 }
        let set = LibraryCollection(name: name)
        try commit(sets + [set]); return set.id
    }
    func rename(_ id: UUID, to name: String) throws {
        try edit(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    func add(_ resource: LibraryResource, to id: UUID) throws {
        try edit(id) { set in
            if !set.members.contains(where: { $0.id == resource.id }) { set.members.append(.init(resource)) }
        }
    }
    func add(_ resources: [LibraryResource], to id: UUID) throws {
        try edit(id) { collection in
            var known = Set(collection.members.map(\.id))
            for resource in resources where known.insert(resource.id).inserted {
                collection.members.append(.init(resource))
            }
        }
    }
    func removeMember(_ resourceID: String, from id: UUID) throws {
        try edit(id) { $0.members.removeAll { $0.id == resourceID } }
    }
    func moveMember(_ resourceID: String, in id: UUID, by delta: Int) throws {
        guard delta == -1 || delta == 1 else { return }
        try edit(id) { set in
            guard let index = set.members.firstIndex(where: { $0.id == resourceID }), set.members.indices.contains(index + delta) else { return }
            set.members.swapAt(index, index + delta)
        }
    }
    func remove(_ id: UUID) throws { try commit(sets.filter { $0.id != id }) }
    private func edit(_ id: UUID, _ change: (inout LibraryCollection) -> Void) throws {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { throw PersonalStateError.invalid(L("La colección ya no está disponible.")) }
        var next = sets; change(&next[index]); try commit(next)
    }
    private func commit(_ next: [LibraryCollection]) throws {
        guard canSave else { throw PersonalStateError.invalid(loadError ?? L("No se pudieron leer las colecciones.")) }
        guard next != sets else { return }
        let snapshot = LibraryCollectionsSnapshot(sets: next)
        try snapshot.validate(); try file.save(snapshot); sets = next; loadError = nil
    }
}
