import Foundation
import Observation
import LibronixCore

@MainActor @Observable final class WorkspaceReferenceSearchController {
    var query = ""
    var resourceID: String?
    var includeLibrary = true
    var allResources = false
    var includeDocuments = true
    private(set) var isSearching = false
    private(set) var report: BibleReferenceSearchReport?
    private(set) var progress: BibleReferenceSearchProgress?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let provider: @Sendable () -> any LibrarySearchContentProvider
    init(provider: @escaping @Sendable () -> any LibrarySearchContentProvider = {
        PersistentLibrarySearchProvider(source: WorkspaceSearchReader())
    }) { self.provider = provider }
    func cancel() {
        generation += 1; task?.cancel(); task = nil; isSearching = false
    }
    func clear() { cancel(); report = nil; progress = nil; error = nil }
    func showOpeningError(_ message: String) { error = message }
    func run(resources: [LibraryResource], documents: [StudyDocument]) {
        clear(); let token = generation
        do {
            let parsed = try BibleReferenceQuery.parse(query)
            let selected = includeLibrary ? (allResources ? resources : resources.filter { $0.id == resourceID }) : []
            let personal = includeDocuments ? documents : []
            guard !includeLibrary || !selected.isEmpty else {
                throw PersonalStateError.invalid("Selecciona un recurso para buscar en la biblioteca.")
            }
            guard !selected.isEmpty || !personal.isEmpty else {
                throw PersonalStateError.invalid("Selecciona un recurso o documentos personales para buscar.")
            }
            isSearching = true
            let provider = provider()
            task = Task { [weak self] in
                do {
                    let report = try await Self.execute(provider: provider, resources: selected, documents: personal,
                        query: parsed, onProgress: { [weak self] value in await self?.receive(value, token: token) })
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.report = report; self.isSearching = false; self.task = nil
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.error = error.localizedDescription; self.isSearching = false; self.task = nil
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    // Build immutable editor projections off the main executor before scanning.
    nonisolated private static func execute(provider: any LibrarySearchContentProvider,
        resources: [LibraryResource], documents: [StudyDocument], query: BibleReferenceQuery,
        onProgress: @escaping @Sendable (BibleReferenceSearchProgress) async -> Void) async throws -> BibleReferenceSearchReport {
        let sources = try documents.map(PersonalReferenceProjection.source)
        return try await BibleReferenceSearchService(provider: provider).search(resources: resources, documents: sources,
            query: query, budget: .init(maximumDurationSeconds: 120, maximumArticles: 250_000, maximumResults: 500),
            onProgress: onProgress)
    }
    private func receive(_ value: BibleReferenceSearchProgress, token: Int) {
        if generation == token { progress = value }
    }
    deinit { task?.cancel() }
}

@MainActor extension StudyWorkspace {
    func beginReferenceSearch() {
        referenceSearch.resourceID = activeReader?.resource.id
        activeTool = .referenceSearch
    }
    func openReferenceSearchResult(_ result: BibleReferenceSearchResult) {
        if let destination = result.resourceDestination {
            guard availableResources.contains(where: { $0.id == destination.resourceID }) else {
                referenceSearch.showOpeningError(L("Recurso no disponible")); return
            }
            openSearchResult(destination); return
        }
        guard let destination = result.personalDestination else { return }
        do {
            _ = try PersonalReferenceProjection.validate(destination, documents: personal.documents)
            personal.selectedDocumentID = destination.documentID
            personalSearchDestination = destination
            personalNavigationID = UUID()
            activeTool = .documents
        } catch { referenceSearch.showOpeningError(error.localizedDescription) }
    }
}
