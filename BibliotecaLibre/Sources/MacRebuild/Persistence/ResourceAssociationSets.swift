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
    var original: ImportedResourceAssociation? = nil
    var originalBindings: [String: LibraryCollectionMember]? = nil
    func supports(_ resource: LibraryResource) -> Bool {
        if scope.supports(resource) { return true }
        guard scope.kind == .series, let original,
              !resource.isHelp, resource.format != .logosModern, resource.support != .invalidFile else { return false }
        let aliases = ImportedResourceAssociation.identifiers(resource)
        guard original.group.resourceIDs.contains(where: { aliases.contains($0.lowercased()) }) else { return false }
        return scope.language.isEmpty || LibronMetadata.deriving(resource).languages.map(LibraryLanguages.canonical).contains(scope.language)
    }
    func supports(_ resource: LibraryResource, using catalog: ResourceAssociationCatalog) -> Bool {
        if scope.supports(resource) { return true }
        guard scope.kind == .series, let original, !resource.isHelp, resource.format != .logosModern, resource.support != .invalidFile,
              original.group.resourceIDs.contains(where: { catalog.legacyIDs[$0.lowercased()]?.contains(resource) == true }) else { return false }
        return scope.language.isEmpty || LibronMetadata.deriving(resource).languages.map(LibraryLanguages.canonical).contains(scope.language)
    }
    func candidates(for member: LibraryCollectionMember, using catalog: ResourceAssociationCatalog) -> [LibraryResource] {
        guard let guid = original?.guid(for:member) else {
            return member.resolve(in:catalog.resources).flatMap { supports($0,using:catalog) ? [$0] : nil } ?? []
        }
        return (catalog.legacyIDs[guid.lowercased()] ?? []).filter { resource in
            if scope.supports(resource) { return true }
            guard scope.kind == .series, !resource.isHelp, resource.format != .logosModern, resource.support != .invalidFile else { return false }
            return scope.language.isEmpty || LibronMetadata.deriving(resource).languages.map(LibraryLanguages.canonical).contains(scope.language)
        }
    }
    func candidates(for member: LibraryCollectionMember, in resources: [LibraryResource]) -> [LibraryResource] {
        candidates(for:member,using:.init(resources:resources))
    }
    func resolve(_ member: LibraryCollectionMember, using catalog: ResourceAssociationCatalog) -> LibraryResource? {
        let choices = candidates(for:member,using:catalog)
        if let bound = originalBindings?[member.id] { return bound.resolve(in:choices) }
        return choices.count == 1 ? choices.first : nil
    }
    func resolve(_ member: LibraryCollectionMember, in resources: [LibraryResource]) -> LibraryResource? {
        if original == nil { return member.resolve(in:resources).flatMap { scope.supports($0) ? $0 : nil } }
        return resolve(member,using:.init(resources:resources))
    }
    func isAmbiguous(_ member: LibraryCollectionMember, using catalog: ResourceAssociationCatalog) -> Bool {
        original?.guid(for:member) != nil && originalBindings?[member.id] == nil && candidates(for:member,using:catalog).count > 1
    }

}
struct ResourceAssociationSetsSnapshot: Codable {
    var schemaVersion = 1
    var sets: [ResourceAssociationSet] = []
    @MainActor func validate() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw PersonalStateError.futureVersion }
        guard sets.count <= 128 else { throw PersonalStateError.invalid(L("Demasiadas asociaciones de recursos.")) }
        // Reuse the established identity/path/name validation, without accepting rule collections.
        try LibraryCollectionsSnapshot(sets: sets.map { .init(id: $0.id, name: $0.name, members: $0.members) }).validate()
        for set in sets {
            guard set.members.count <= 256 else { throw PersonalStateError.invalid(L("Demasiados recursos en la asociación.")) }
            try set.scope.validate()
            if let original = set.original {
                guard schemaVersion == 2 else { throw PersonalStateError.futureVersion }
                try original.validate()
            }
            for member in set.members where ImportedResourceAssociation.isReserved(member) {
                guard set.original?.guid(for:member) != nil else { throw LegacyIndicesError.sourceChanged }
            }
            for (id,binding) in set.originalBindings ?? [:] {
                guard schemaVersion == 2, let member = set.members.first(where: { $0.id == id }),
                      set.original?.guid(for:member) != nil, !ImportedResourceAssociation.isReserved(binding) else { throw LegacyIndicesError.sourceChanged }
                try LibraryCollectionsSnapshot(sets:[.init(name:"Binding",members:[binding])]).validate()
            }
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
                var prospective = value; prospective.scope = scope
                guard value.members.allSatisfy({ prospective.resolve($0,in:resources) != nil }) else { throw PersonalStateError.invalid(L("Quita los recursos no disponibles o incompatibles antes de cambiar el tipo, idioma o serie.")) }
            }
            value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.relation = relation; value.scope = scope
        }
    }
    func add(_ resources: [LibraryResource], to id: UUID) throws {
        try edit(id) { value in
            guard resources.allSatisfy(value.supports) else {
                throw PersonalStateError.invalid(L("El recurso no es compatible con esta asociación."))
            }
            var known = Set(value.members.map(\.id))
            for resource in resources where known.insert(resource.id).inserted {
                let aliases = ImportedResourceAssociation.identifiers(resource)
                if !value.members.contains(where: { member in value.original?.guid(for:member).map { aliases.contains($0.lowercased()) } == true }) {
                    value.members.append(.init(resource))
                }
            }
        }
    }
    func removeMember(_ resourceID: String, from id: UUID) throws {
        try edit(id) { $0.members.removeAll { $0.id == resourceID }; $0.originalBindings?[resourceID] = nil }
    }
    func moveMember(_ resourceID: String, in id: UUID, by delta: Int) throws {
        guard delta == -1 || delta == 1 else { return }
        try edit(id) { value in
            guard let index = value.members.firstIndex(where: { $0.id == resourceID }), value.members.indices.contains(index + delta) else { return }
            value.members.swapAt(index, index + delta)
        }
    }
    func bind(_ memberID: String, in id: UUID, to resource: LibraryResource?, resources: [LibraryResource]) throws {
        try edit(id) { value in
            guard let member = value.members.first(where: { $0.id == memberID }), value.original?.guid(for:member) != nil else { throw LegacyIndicesError.sourceChanged }
            if let resource {
                guard value.candidates(for:member,in:resources).contains(resource) else { throw RebuildError.unsupportedFormat }
                if value.originalBindings == nil { value.originalBindings = [:] }
                value.originalBindings?[memberID] = .init(resource)
            } else { value.originalBindings?[memberID] = nil }
        }
    }
    @discardableResult func importOriginal(_ document: ResourceAssociationDocument, relation: AssociationRelation,
                                           kind: AssociationResourceKind = .series, language: String = "",
                                           resources: [LibraryResource]) throws -> [UUID] {
        let definition = document.definition
        guard !definition.groups.isEmpty else { throw PersonalStateError.invalid(L("La definición no contiene asociaciones activas.")) }
        guard definition.groups.count <= 128, document.data.count <= 8 * 1024 * 1024 / definition.groups.count else { throw PersonalStateError.tooLarge }
        var next = sets, ids: [UUID] = []
        let catalog = ResourceAssociationCatalog(resources:resources)
        for index in definition.groups.indices {
            let original = ImportedResourceAssociation(document:document,groupIndex:index)
            if let existing = next.first(where: { $0.original?.identity == original.identity }) { ids.append(existing.id); continue }
            var base = ""
            for character in definition.title {
                guard base.utf16.count + String(character).utf16.count <= 140 else { break }; base.append(character)
            }
            if base.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { base = L("Nueva asociación") }
            if definition.groups.count > 1 { base += " · " + String(index + 1) }
            var name = base, counter = 2
            while next.contains(where: { $0.name == name }) { name = base + " (" + String(counter) + ")"; counter += 1 }
            let scope = AssociationResourceScope(kind:kind,language:LibraryLanguages.canonical(language),series:kind == .series ? base : "")
            var value = ResourceAssociationSet(name:name,relation:relation,scope:scope,original:original)
            for (position,guid) in original.group.resourceIDs.enumerated() {
                let placeholder = LibraryResource(location:URL(fileURLWithPath:original.memberID(position)),title:guid,
                    byteCount:0,format:.libronixLLS,support:.metadataOnly,provenance:.fileName,legacyIdentifier:guid)
                var member = LibraryCollectionMember(placeholder)
                let choices = value.candidates(for:member,using:catalog)
                if choices.count == 1 { member.title = choices[0].title }
                value.members.append(member)
            }
            next.append(value); ids.append(value.id)
        }
        try commit(next); return ids
    }
    func remove(_ id: UUID) throws { try commit(sets.filter { $0.id != id }) }
    private func edit(_ id: UUID, _ action: (inout ResourceAssociationSet) throws -> Void) throws {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { throw PersonalStateError.invalid(L("La asociación ya no está disponible.")) }
        var next = sets; try action(&next[index]); try commit(next)
    }
    private func commit(_ next: [ResourceAssociationSet]) throws {
        guard canSave else { throw PersonalStateError.invalid(loadError ?? L("No se pudieron leer las asociaciones.")) }
        guard next != sets else { return }
        let snapshot = ResourceAssociationSetsSnapshot(schemaVersion: next.contains { $0.original != nil } ? 2 : 1, sets: next); try snapshot.validate(); try file.save(snapshot)
        sets = next; loadError = nil
    }
}
