import Foundation
import LibronixCore
import Observation

@MainActor @Observable final class LibrarySearchModel {
    var queryText = ""
    var searchAllResources = false
    var caseSensitive = false
    var diacriticSensitive = true
    var wholeWords = true
    var unit = LibrarySearchUnit.article
    var isSearching = false
    var progress: LibrarySearchProgress?
    var report: LibrarySearchReport?
    var errorMessage: String?
    var submittedQuery = ""
    var focusRequest = 0
    @ObservationIgnored private let service = LibrarySearchService()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func cancel() { task?.cancel(); generation += 1; isSearching = false; progress = nil }
    func run(resources: [LibraryResource], selectedResource: LibraryResource?) {
        let scope = searchAllResources ? resources : selectedResource.map { [$0] } ?? []
        guard !scope.isEmpty else { errorMessage = "Selecciona un recurso o elige toda la biblioteca."; return }
        let query: SearchQuery
        do { query = try SearchQueryParser.parse(queryText) }
        catch let error as SearchQueryError {
            errorMessage = "Consulta no válida (posición \(error.range.location + 1)): \(error.message)"; return
        } catch { errorMessage = error.localizedDescription; return }
        task?.cancel(); generation += 1
        let request = generation
        isSearching = true; progress = nil; report = nil; errorMessage = nil
        submittedQuery = query.source
        let options = TextSearchOptions(caseSensitive: caseSensitive, diacriticSensitive: diacriticSensitive, wholeWords: wholeWords)
        let unit = unit
        task = Task { [weak self, service] in
            do {
                let result = try await service.search(resources: scope, query: query, options: options, unit: unit,
                    budget: LibrarySearchBudget()) { [weak self] value in
                        await MainActor.run {
                            guard let self, self.generation == request else { return }
                            self.progress = value
                        }
                    }
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.report = result; self.progress = nil; self.isSearching = false
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == request else { return }
                self.errorMessage = error.localizedDescription; self.progress = nil; self.isSearching = false
            }
        }
    }
}
