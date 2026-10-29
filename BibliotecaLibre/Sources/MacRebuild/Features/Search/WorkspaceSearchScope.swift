import Foundation
import Observation
import LibronixCore

enum WorkspaceSearchScopeKind: String, Codable, CaseIterable, Sendable {
    case resource, library, collections, subset, openReaders
    @MainActor var title: String {
        switch self {
        case .resource: L("Recurso")
        case .library: L("Toda la biblioteca")
        case .collections: L("Colecciones")
        case .subset: L("Recursos seleccionados")
        case .openReaders: L("Lectores abiertos")
        }
    }
}
enum WorkspaceSearchScopeError: Error, LocalizedError {
    case invalidIdentity, noCollections, noResources, unavailableResource
    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidIdentity: key = "El ámbito contiene identidades de recurso incompatibles."
        case .noCollections: key = "Selecciona una o varias colecciones para buscar."
        case .noResources: key = "El ámbito no contiene recursos disponibles para buscar."
        case .unavailableResource: key = "El recurso del resultado ya no conserva su identidad o disponibilidad."
        }
        return AppStrings.text(key, language: .saved())
    }
}
@MainActor @Observable final class WorkspaceSearchScopeSelection {
    var kind = WorkspaceSearchScopeKind.resource
    var resourceID: String?
    var collectionIDs: Set<UUID> = []
    var members: [LibraryCollectionMember] = []
    private(set) var unresolvedSubsetIDs: Set<String> = []
    var selectedSubsetIDs: Set<String> { Set(members.map(\.id)).union(unresolvedSubsetIDs) }
    func clearSubset() { members = []; unresolvedSubsetIDs = [] }
    func restoreSubset(members: [LibraryCollectionMember], unresolvedIDs: Set<String>) {
        self.members = members
        unresolvedSubsetIDs = unresolvedIDs
    }
    // Keep the existing controller API and toolbar behavior available.
    var allResources: Bool {
        get { kind == .library }
        set { kind = newValue ? .library : .resource }
    }
    func selectSubset(_ ids: Set<String>, in resources: [LibraryResource]) {
        let previous = members
        var next: [LibraryCollectionMember] = [], unresolved = Set<String>()
        for id in ids.sorted() {
            if let member = previous.first(where: { $0.id == id }) ?? resources.first(where: { $0.id == id }).map(LibraryCollectionMember.init) {
                next.append(member)
            } else { unresolved.insert(id) }
        }
        members = next; unresolvedSubsetIDs = unresolved
    }
}

struct WorkspaceSearchScopeContext: Sendable {
    var library: [LibraryResource]
    var openResources: [LibraryResource] = []
    var collections: [LibraryCollection] = []
    var hidden: [HiddenLibraryResource] = []
    var collectionsError: String?
    var visibilityError: String?
    func isHidden(_ resource: LibraryResource) -> Bool { hidden.contains { $0.matches(resource) } }
    func choices() -> [LibraryResource] {
        var seen = Set<String>()
        let hiddenByID = hidden.reduce(into: [String: HiddenLibraryResource]()) { $0[$1.id] = $1 }
        return (library + openResources).filter { hiddenByID[$0.id]?.matches($0) != true && seen.insert($0.id).inserted }
    }
}
struct WorkspaceSearchScopeIssue: Sendable, Codable {
    enum Reason: String, Codable, Sendable { case missing, hidden, changedIdentity, missingCollection }
    let id: String
    let title: String
    let reason: Reason
    @MainActor var description: String {
        let label: String
        switch reason {
        case .missing: label = L("No disponible")
        case .hidden: label = L("Oculto")
        case .changedIdentity: label = L("Identidad del recurso modificada")
        case .missingCollection: label = L("La colección ya no está disponible.")
        }
        return title + ": " + label
    }
}
struct WorkspaceSearchScopeSnapshot: Sendable {
    let kind: WorkspaceSearchScopeKind
    let names: [String]
    let resources: [LibraryResource]
    let externalResourceIDs: Set<String>
    let requestedResourceCount: Int
    let issues: [WorkspaceSearchScopeIssue]
    let fingerprint: String
    var complete: Bool { issues.isEmpty }
    @MainActor var description: String {
        let name = names.isEmpty ? kind.title : kind.title + " · " + names.joined(separator: ", ")
        return name + " · " + LF("{count} recursos", ["count": String(resources.count)])
    }
}

@MainActor enum WorkspaceSearchScopeResolver {
    private struct Identity: Codable, Equatable {
        let id: String
        let format: ResourceFormat
        let legacy: String?
        let location: URL
        let index: URL?
        let package: URL?
        init(_ value: LibraryResource) {
            id = value.id; format = value.format; legacy = value.legacyIdentifier
            location = value.location.standardizedFileURL; index = value.indexLocation?.standardizedFileURL
            package = value.packageLocation?.standardizedFileURL
        }
    }
    static func resolve(_ selection: WorkspaceSearchScopeSelection, context: WorkspaceSearchScopeContext) throws -> WorkspaceSearchScopeSnapshot {
        if let message = context.visibilityError { throw PersonalStateError.invalid(message) }
        guard Set(context.library.map(\.id)).count == context.library.count else { throw WorkspaceSearchScopeError.invalidIdentity }
        guard Set(context.hidden.map(\.id)).count == context.hidden.count else { throw WorkspaceSearchScopeError.invalidIdentity }
        let library = Dictionary(uniqueKeysWithValues: context.library.map { ($0.id, $0) })
        let hidden = Dictionary(uniqueKeysWithValues: context.hidden.map { ($0.id, $0) })
        func isHidden(_ resource: LibraryResource) -> Bool { hidden[resource.id]?.matches(resource) == true }
        var pool = library, readers: [LibraryResource] = [], seenReaders: [String: Identity] = [:]
        for resource in context.openResources {
            if let previous = seenReaders[resource.id] {
                if selection.kind == .openReaders, previous != Identity(resource) { throw WorkspaceSearchScopeError.invalidIdentity }
                continue
            }
            seenReaders[resource.id] = Identity(resource); readers.append(resource)
            if let current = pool[resource.id] {
                if selection.kind == .openReaders, Identity(current) != Identity(resource) { throw WorkspaceSearchScopeError.invalidIdentity }
            } else { pool[resource.id] = resource }
        }
        var names: [String] = [], requested: [LibraryCollectionMember] = [], issues: [WorkspaceSearchScopeIssue] = [], unresolvedCount = 0
        switch selection.kind {
        case .resource:
            if let id = selection.resourceID, let resource = pool[id] { requested = [.init(resource)] }
            else if let id = selection.resourceID { issues.append(.init(id: id, title: id, reason: .missing)); unresolvedCount = 1 }
        case .library:
            requested = context.library.filter { !isHidden($0) }.map(LibraryCollectionMember.init)
        case .openReaders:
            requested = readers.map(LibraryCollectionMember.init)
        case .subset:
            requested = selection.members
            let missing = selection.unresolvedSubsetIDs.subtracting(Set(requested.map(\.id)))
            issues += missing.sorted().map { .init(id: $0, title: $0, reason: .missing) }; unresolvedCount = missing.count
        case .collections:
            if let message = context.collectionsError { throw PersonalStateError.invalid(message) }
            guard !selection.collectionIDs.isEmpty else { throw WorkspaceSearchScopeError.noCollections }
            guard Set(context.collections.map(\.id)).count == context.collections.count else { throw WorkspaceSearchScopeError.invalidIdentity }
            for id in selection.collectionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let set = context.collections.first(where: { $0.id == id }) else {
                    issues.append(.init(id: id.uuidString, title: id.uuidString, reason: .missingCollection)); continue
                }
                if let rule = set.rule { try rule.validate() }
                names.append(set.name); requested += set.resolvedMembers(in: context.library)
            }
        }
        var unique: [String: LibraryCollectionMember] = [:], order: [String] = []
        for member in requested {
            if let existing = unique[member.id] {
                guard existing.format == member.format, existing.legacyIdentifier == member.legacyIdentifier else { throw WorkspaceSearchScopeError.invalidIdentity }
            } else { unique[member.id] = member; order.append(member.id) }
        }
        var resolved: [LibraryResource] = []
        for id in order {
            let member = unique[id]!
            guard let resource = pool[id] else { issues.append(.init(id: id, title: member.title, reason: .missing)); continue }
            guard member.resolve(in: [resource]) != nil else { issues.append(.init(id: id, title: member.title, reason: .changedIdentity)); continue }
            guard !isHidden(resource) else { issues.append(.init(id: id, title: member.title, reason: .hidden)); continue }
            resolved.append(resource)
        }
        struct Witness: Encodable {
            let kind: WorkspaceSearchScopeKind; let names: [String]; let identities: [Identity]
            let requested: [LibraryCollectionMember]; let issues: [WorkspaceSearchScopeIssue]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Witness(kind: selection.kind, names: names, identities: resolved.map(Identity.init), requested: order.compactMap { unique[$0] }, issues: issues))
        return .init(kind: selection.kind, names: names, resources: resolved,
            externalResourceIDs: Set(resolved.filter { library[$0.id] == nil }.map(\.id)), requestedResourceCount: unique.count + unresolvedCount,
            issues: issues, fingerprint: LibrarySearchService.textFingerprint(String(decoding: bytes, as: UTF8.self)))
    }
}
@MainActor extension StudyWorkspace {
    func searchScopeContext() -> WorkspaceSearchScopeContext {
        .init(library: resources, openResources: orderedReaders.map(\.resource), collections: collections.sets,
            hidden: resourceVisibility.hidden, collectionsError: collections.loadError, visibilityError: resourceVisibility.loadError)
    }
    func resourceForSearchResult(_ result: LibrarySearchResult, scope: WorkspaceSearchScopeSnapshot?) throws -> LibraryResource {
        guard let scope else {
            guard let resource = availableResources.first(where: { $0.id == result.resourceID }) else { throw WorkspaceSearchScopeError.unavailableResource }
            return resource
        }
        guard let source = scope.resources.first(where: { $0.id == result.resourceID }), !resourceVisibility.isHidden(source) else { throw WorkspaceSearchScopeError.unavailableResource }
        if let current = resources.first(where: { $0.id == source.id }) {
            guard current.format == source.format, current.legacyIdentifier == source.legacyIdentifier,
                  current.location.standardizedFileURL == source.location.standardizedFileURL else { throw WorkspaceSearchScopeError.unavailableResource }
        } else if !scope.externalResourceIDs.contains(source.id) { throw WorkspaceSearchScopeError.unavailableResource }
        return source
    }
}
