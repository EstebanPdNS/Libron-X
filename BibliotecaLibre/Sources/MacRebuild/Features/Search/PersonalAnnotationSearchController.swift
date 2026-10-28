import Foundation
import Observation
import LibronixCore

@MainActor @Observable final class PersonalAnnotationSearchController {
    var query = ""
    var filter = PersonalAnnotationSearchFilter()
    private(set) var report: PersonalAnnotationReport?
    private(set) var isSearching = false
    var error: String?
    @ObservationIgnored private let service: PersonalAnnotationSearch
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    init(provider: any LibrarySearchContentProvider = WorkspaceSearchReader()) { service = .init(provider: provider) }
    func clear() { generation += 1; task?.cancel(); task = nil; report = nil; error = nil; isSearching = false }
    func run(documents: [StudyDocument], highlights: [ReaderHighlight], resources: [LibraryResource]) {
        clear(); let token = generation, query = query, filter = filter, service = service
        isSearching = true
        task = Task { [weak self] in
            do {
                let report = try await service.search(query: query, documents: documents, highlights: highlights, resources: resources, filter: filter)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.report = report; self.isSearching = false; self.task = nil
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isSearching = false; self.task = nil
            }
        }
    }
    deinit { task?.cancel() }
}

@MainActor extension StudyWorkspace {
    func openPersonalAnnotationResult(_ result: PersonalAnnotationResult) {
        do {
            switch result.destination {
            case .note(let destination):
                _ = try PersonalReferenceProjection.validate(destination, documents: personal.documents)
                personal.selectedDocumentID = destination.documentID
                personalSearchDestination = destination; personalNavigationID = UUID(); activeTool = .documents
            case let .highlight(mark, resource, stamps, range):
                guard personal.highlights.contains(mark), availableResources.contains(resource) else {
                    throw PersonalStateError.invalid(L("El resultado cambió o ya no está disponible. Repite la búsqueda antes de abrirlo."))
                }
                try LibrarySearchFileStamp.verify(stamps)
                let reader = open(resource, startReading: false)
                reader.load(.init(ordinal: mark.ordinal), selection: range.nsRange,
                            expectedFingerprint: mark.fingerprint, expectedSourceStamps: stamps)
                activeTool = nil
            }
        } catch { annotationSearch.error = error.localizedDescription }
    }
}
