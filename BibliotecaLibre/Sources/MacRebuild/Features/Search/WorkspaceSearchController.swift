import Foundation
import Observation
import LibronixCore

@MainActor @Observable final class WorkspaceSearchController {
    var query = ""
    var resourceID: String?
    var allResources = false
    var caseSensitive = false
    var wholeWords = true
    var bibleVerses = false
    var isSearching = false
    var report: LibrarySearchReport?
    var progress: LibrarySearchProgress?
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    func cancel() { generation += 1; task?.cancel(); task = nil; isSearching = false }
    func run(_ resources: [LibraryResource]) {
        cancel(); let token = generation
        let selected = allResources ? resources : resources.filter { $0.id == resourceID }
        guard !selected.isEmpty else { error = L("Selecciona un recurso para buscar."); return }
        do {
            let parsed = try SearchQueryParser.parse(query)
            var options = TextSearchOptions(); options.caseSensitive = caseSensitive; options.wholeWords = wholeWords
            let unit: LibrarySearchUnit = bibleVerses ? .bibleVerse : .article
            isSearching = true; error = nil; report = nil; progress = nil
            task = Task { [weak self] in
                do {
                    let result = try await LibrarySearchService().search(resources: selected, query: parsed, options: options, unit: unit,
                        budget: .init(maximumDurationSeconds: 120, maximumArticles: 250_000, maximumResults: 500), onProgress: { [weak self] value in
                            await self?.receive(value, token: token)
                        })
                    guard let self, token == self.generation, !Task.isCancelled else { return }
                    self.report = result; self.isSearching = false
                } catch {
                    guard let self, token == self.generation, !Task.isCancelled else { return }
                    self.error = error.localizedDescription; self.isSearching = false
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func receive(_ value: LibrarySearchProgress, token: Int) { if generation == token { progress = value } }
}
