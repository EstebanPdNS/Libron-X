import Foundation
import Observation
import LibronixCore

enum AssociationDestinationMode: String, CaseIterable, Identifiable, Sendable {
    case reference, headword, start
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reference: "Referencia bíblica"
        case .headword: "Entrada"
        case .start: "Inicio del recurso"
        }
    }
}

@MainActor @Observable final class AssociationNavigationController {
    typealias Lookup = @Sendable (LibraryResource, AssociationResourceScope, AssociationDestinationMode, String) async throws -> KeyLinkMatch?
    var groupID: UUID? { didSet { if oldValue != groupID { cancel() } } }
    var mode = AssociationDestinationMode.start { didSet { if oldValue != mode { cancel() } } }
    var query = "" { didSet { if oldValue != query { cancel() } } }
    private(set) var sourceID: UUID?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let lookup: Lookup
    init(lookup: @escaping Lookup = AssociationNavigationController.resolve) { self.lookup = lookup }
    func begin(groupID: UUID?, source: ReaderSession?) {
        cancel(); self.sourceID = source?.id; self.groupID = groupID
        if let reference = source?.currentReference { mode = .reference; query = reference }
        else if let source, source.isDictionary, !source.dictionaryWord.isEmpty { mode = .headword; query = source.dictionaryWord }
        else { mode = .start; query = "" }
    }
    func cancel() { generation += 1; task?.cancel(); task = nil; isLoading = false; error = nil }
    func open(_ member: LibraryCollectionMember, workspace: StudyWorkspace, newReader: Bool = false) {
        cancel()
        guard let group = workspace.resourceAssociations.sets.first(where: { $0.id == groupID }),
              group.members.contains(member), let resource = group.resolve(member, in: workspace.availableResources) else {
            error = L("Recurso no disponible o incompatible"); return
        }
        let source = sourceID.flatMap { id in workspace.readers.first { $0.id == id } }
        if sourceID != nil {
            guard let source, !source.isLoading,
                  group.members.contains(where: { group.resolve($0, in: workspace.availableResources) == source.resource }) else {
                error = L("La lectura de origen cambió. Vuelve a abrir los recursos asociados."); return
            }
        }
        let input = mode == .start ? "" : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .start || (!input.isEmpty && input.utf16.count <= 512 && !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)) else {
            error = L("Introduce una referencia o entrada válida."); return
        }
        let token = generation, mode = mode, query = self.query
        let sourceResource = source?.resource, sourceGeneration = source?.associationGeneration
        let sourceReference = source?.currentReference
        let create = newReader || group.relation == .companions || source == nil
        guard create || sourceResource?.id != resource.id else { return }
        isLoading = true
        task = Task { [weak self, weak workspace, weak source, lookup] in
            defer { if let self, self.generation == token { self.isLoading = false; self.task = nil } }
            do {
                guard let match = try await lookup(resource, group.scope, mode, input) else { throw RebuildError.referenceNotFound }
                try Task.checkCancellation()
                guard let self, let workspace, self.generation == token, self.mode == mode, self.query == query else { return }
                guard workspace.resourceAssociations.sets.first(where: { $0.id == group.id }) == group,
                      group.resolve(member, in: workspace.availableResources) == resource else {
                    throw PersonalStateError.invalid(L("La asociación cambió. Ejecuta la acción de nuevo."))
                }
                if let sourceID = self.sourceID {
                    guard let source, workspace.readers.contains(where: { $0 === source && $0.id == sourceID }),
                          source.resource == sourceResource, source.associationGeneration == sourceGeneration,
                          source.currentReference == sourceReference, !source.isLoading else {
                        throw PersonalStateError.invalid(L("La lectura de origen cambió. Vuelve a abrir los recursos asociados."))
                    }
                }
                guard !match.stamps.isEmpty, match.resource == resource, match.destination.ordinal == match.page.destination.ordinal,
                      Set(match.stamps.map(\.url)) == Set(Self.sourceURLs(resource)),
                      match.stamps.count == Self.sourceURLs(resource).count else { throw LegacyIndicesError.sourceChanged }
                try LibrarySearchFileStamp.verify(match.stamps)
                if create {
                    let previousActiveID = workspace.activeID
                    let reader = workspace.open(resource, startReading: false)
                    do { try reader.installAssociation(match, mode: mode) }
                    catch { workspace.close(reader); workspace.activeID = previousActiveID; throw error }
                    reader.textScale = source?.textScale ?? reader.textScale
                } else if let source {
                    try source.installAssociation(match, mode: mode)
                    if workspace.referenceTargetID == source.id, !source.canSynchronizeBible { workspace.referenceTargetID = nil }
                    workspace.connect(source); workspace.activate(source)
                }
                self.isLoading = false; self.task = nil
                if workspace.activeTool == .associationLinks { workspace.activeTool = nil }
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false; self.task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    nonisolated static func resolve(_ resource: LibraryResource, scope: AssociationResourceScope,
                                    mode: AssociationDestinationMode, query: String) async throws -> KeyLinkMatch? {
        try Task.checkCancellation()
        guard scope.supports(resource) else { throw RebuildError.unsupportedFormat }
        if mode != .start {
            let kinds: [KeyLinkKind] = mode == .reference ? [.bible,.commentary] : [.dictionary,.lexicon]
            guard let kind = kinds.first(where: { $0.supports(resource) }) else { throw RebuildError.unsupportedFormat }
            return try await KeyLinkController.resolve(resource, scope: .init(kind: kind, language: scope.language), query: query)
        }
        let stamps = try sourceURLs(resource).map(LibrarySearchFileStamp.capture)
        let page = try await ReaderSession.read(resource, .init(ordinal: 0, prefersContentsStart: true))
        try Task.checkCancellation(); try LibrarySearchFileStamp.verify(stamps)
        return .init(resource: resource, destination: page.destination, label: "", page: page, stamps: stamps)
    }
    nonisolated static func sourceURLs(_ resource: LibraryResource) -> [URL] {
        var urls = [resource.location]
        if let index = resource.indexLocation { urls.append(index) }
        if let package = resource.packageLocation { urls.append(package.appendingPathComponent("manifest.json")) }
        if let native = LibronNativeReader.location(resource) { urls.append(native) }
        return urls
    }
    deinit { task?.cancel() }
}

@MainActor extension StudyWorkspace {
    func beginAssociatedResources(groupID: UUID? = nil, source: ReaderSession? = nil) {
        let source = source ?? activeReader
        let eligible = resourceAssociations.sets.filter { group in
            source.map { reader in group.members.contains { group.resolve($0, in: availableResources) == reader.resource } } ?? true
        }
        let selected = groupID.flatMap { id in resourceAssociations.sets.first { $0.id == id } } ?? eligible.first
        let memberSource = source.flatMap { reader in
            selected?.members.contains { selected?.resolve($0, in: availableResources) == reader.resource } == true ? reader : nil
        }
        associationNavigation.begin(groupID: selected?.id, source: memberSource)
        activeTool = .associationLinks
    }
}
