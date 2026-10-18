import Foundation
import Observation
import LibronixCore

enum AssociationRelation: String, Codable, CaseIterable, Identifiable, Sendable {
    case alternatives, companions
    var id: String { rawValue }
    var title: String { self == .alternatives ? "Alternativos" : "Complementarios" }
}
enum AssociationResourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bible, commentary, dictionary, lexicon, series
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bible: "Biblia"
        case .commentary: "Comentario bíblico"
        case .dictionary: "Diccionario"
        case .lexicon: "Léxico"
        case .series: "Serie"
        }
    }
}
struct AssociationResourceScope: Codable, Equatable, Sendable {
    var kind: AssociationResourceKind = .bible
    var language = ""
    var series = ""
    @MainActor func validate() throws {
        let parts = language.split(separator: "-", omittingEmptySubsequences: false)
        let validLanguage = language.isEmpty || ((2...8).contains(parts[0].count) && parts[0].allSatisfy({ $0.isASCII && $0.isLetter }) &&
            parts.dropFirst().allSatisfy({ (1...8).contains($0.count) && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) }))
        guard validLanguage, language.utf8.count <= 32,
              language.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              language.isEmpty || LibraryLanguages.canonical(language) == language,
              series.utf16.count <= 256, !series.contains("\0"),
              kind == .series ? !series.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : series.isEmpty else {
            throw PersonalStateError.invalid(L("El tipo, idioma o serie de la asociación no es válido."))
        }
    }
    func supports(_ resource: LibraryResource) -> Bool {
        guard !resource.isHelp, resource.format != .logosModern, resource.support != .invalidFile else { return false }
        let metadata = LibronMetadata.deriving(resource)
        let accepted: Bool
        switch kind {
        case .bible: accepted = KeyLinkKind.bible.supports(resource)
        case .commentary: accepted = KeyLinkKind.commentary.supports(resource)
        case .dictionary: accepted = KeyLinkKind.dictionary.supports(resource)
        case .lexicon: accepted = KeyLinkKind.lexicon.supports(resource)
        case .series:
            let normalize: (String) -> String = {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            }
            accepted = !series.isEmpty && metadata.collection.map { normalize($0) == normalize(series) } == true
        }
        guard accepted else { return false }
        if language.isEmpty { return true }
        if kind == .dictionary || kind == .lexicon {
            return KeyLinkScope(kind: kind == .dictionary ? .dictionary : .lexicon, language: language).supports(resource)
        }
        return metadata.languages.map(LibraryLanguages.canonical).contains(language)
    }
}
struct ResourceAssociationSet: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var relation: AssociationRelation = .alternatives
    var scope = AssociationResourceScope()
    var members: [LibraryCollectionMember] = []
    func resolve(_ member: LibraryCollectionMember, in resources: [LibraryResource]) -> LibraryResource? {
        guard let resource = member.resolve(in: resources), scope.supports(resource) else { return nil }
        return resource
    }
}
struct ResourceAssociationSetsSnapshot: Codable {
    var schemaVersion = 1
    var sets: [ResourceAssociationSet] = []
    @MainActor func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard sets.count <= 128 else { throw PersonalStateError.invalid(L("Demasiadas asociaciones de recursos.")) }
        // Reuse the established identity/path/name validation, without accepting rule collections.
        try LibraryCollectionsSnapshot(sets: sets.map { .init(id: $0.id, name: $0.name, members: $0.members) }).validate()
        for set in sets {
            guard set.members.count <= 256 else { throw PersonalStateError.invalid(L("Demasiados recursos en la asociación.")) }
            try set.scope.validate()
        }
    }
}

/// Separate owned definitions: never rewrites books, original .lbxras files or Bible sets.
@MainActor @Observable final class ResourceAssociationSets {
    private(set) var sets: [ResourceAssociationSet] = []
    private(set) var loadError: String?
    @ObservationIgnored private let file: PersonalStateFile<ResourceAssociationSetsSnapshot>
    @ObservationIgnored private var canSave = false
    init(url: URL? = nil) {
        file = .init(url: url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/resource-associations.json"))
        do { try reload() } catch { loadError = error.localizedDescription }
    }
    func reload() throws {
        canSave = false
        do {
            let value = try file.load() ?? .init(); try value.validate()
            sets = value.sets; canSave = true; loadError = nil
        } catch { loadError = error.localizedDescription; throw error }
    }
    @discardableResult func create() throws -> UUID {
        let base = L("Nueva asociación")
        var name = base, number = 2
        while sets.contains(where: { $0.name == name }) { name = "\(base) \(number)"; number += 1 }
        let value = ResourceAssociationSet(name: name); try commit(sets + [value]); return value.id
    }
    func configure(_ id: UUID, name: String, relation: AssociationRelation, scope: AssociationResourceScope,
                   resources: [LibraryResource]) throws {
        try scope.validate()
        try edit(id) { value in
            // Missing or newly incompatible members must remain visible, never silently discarded.
            if value.scope != scope {
                guard value.members.allSatisfy({ member in
                    member.resolve(in: resources).map(scope.supports) == true
                }) else { throw PersonalStateError.invalid(L("Quita los recursos no disponibles o incompatibles antes de cambiar el tipo, idioma o serie.")) }
            }
            value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.relation = relation; value.scope = scope
        }
    }
    func add(_ resources: [LibraryResource], to id: UUID) throws {
        try edit(id) { value in
            guard resources.allSatisfy(value.scope.supports) else {
                throw PersonalStateError.invalid(L("El recurso no es compatible con esta asociación."))
            }
            var known = Set(value.members.map(\.id))
            for resource in resources where known.insert(resource.id).inserted { value.members.append(.init(resource)) }
        }
    }
    func removeMember(_ resourceID: String, from id: UUID) throws {
        try edit(id) { $0.members.removeAll { $0.id == resourceID } }
    }
    func moveMember(_ resourceID: String, in id: UUID, by delta: Int) throws {
        guard delta == -1 || delta == 1 else { return }
        try edit(id) { value in
            guard let index = value.members.firstIndex(where: { $0.id == resourceID }), value.members.indices.contains(index + delta) else { return }
            value.members.swapAt(index, index + delta)
        }
    }
    func remove(_ id: UUID) throws { try commit(sets.filter { $0.id != id }) }
    private func edit(_ id: UUID, _ action: (inout ResourceAssociationSet) throws -> Void) throws {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { throw PersonalStateError.invalid(L("La asociación ya no está disponible.")) }
        var next = sets; try action(&next[index]); try commit(next)
    }
    private func commit(_ next: [ResourceAssociationSet]) throws {
        guard canSave else { throw PersonalStateError.invalid(loadError ?? L("No se pudieron leer las asociaciones.")) }
        guard next != sets else { return }
        let snapshot = ResourceAssociationSetsSnapshot(sets: next); try snapshot.validate(); try file.save(snapshot)
        sets = next; loadError = nil
    }
}
