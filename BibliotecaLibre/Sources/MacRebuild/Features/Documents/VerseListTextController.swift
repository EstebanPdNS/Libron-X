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
    init(provider: any LibrarySearchContentProvider = WorkspaceSearchReader()) {
        service = .init(provider: provider)
    }
    func invalidate() {
        generation += 1; task?.cancel(); task = nil
        report = nil; rowsByID = [:]; error = nil; isLoading = false
    }
    func load(document: StudyDocument, resource: LibraryResource) {
        invalidate()
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
