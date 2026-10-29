import Foundation
import LibronixCore
import Observation

/// A report is tied to the exact list and resource from which it was requested.
@MainActor @Observable final class VerseListTextController {
    private(set) var report: StudyVerseListReport?
    private(set) var rowsByID: [UUID: StudyVerseListRow] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private let service: StudyVerseListReportService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var request: Request?
    private struct Request: Equatable {
        let documentID: UUID
        let verses: [StudyVerseEntry]
        let resource: LibraryResource
    }
    init(provider: any LibrarySearchContentProvider = WorkspaceSearchReader()) {
        service = .init(provider: provider)
    }
    func synchronize(document: StudyDocument?, resources: [LibraryResource]) {
        guard let document, document.kind == .verseList, !document.verses.isEmpty,
              let resource = document.verseListEdition?.resolve(in: resources) else { invalidate(); return }
        let next = Request(documentID: document.id, verses: document.verses, resource: resource)
        guard request != next else { return }
        load(document: document, resource: resource)
    }
    func invalidate() {
        cancel(); request = nil
    }
    func cancel() {
        generation += 1; task?.cancel(); task = nil
        report = nil; rowsByID = [:]; error = nil; isLoading = false
    }
    func load(document: StudyDocument, resource: LibraryResource) {
        invalidate()
        request = Request(documentID: document.id, verses: document.verses, resource: resource)
        let token = generation, service = service
        isLoading = true
        task = Task { [weak self] in
            do {
                let report = try await service.read(document, resource: resource)
                if let edition = report.edition { try LibrarySearchFileStamp.verify(edition.sourceStamps) }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.report = report; self.rowsByID = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.entryID, $0) })
                self.isLoading = false; self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false; self.task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    deinit { task?.cancel() }
}
