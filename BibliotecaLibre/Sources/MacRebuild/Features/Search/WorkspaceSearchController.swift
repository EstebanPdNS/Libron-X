import Foundation
import Observation
import LibronixCore

enum WorkspaceBibleRangeMode: String, CaseIterable, Sendable { case all, custom, savedList }

@MainActor @Observable final class WorkspaceSearchController {
    var query = ""
    var resourceID: String?
    var allResources = false
    var caseSensitive = false
    var wholeWords = true
    var bibleVerses = false
    var bibleRangeMode = WorkspaceBibleRangeMode.all
    var customBibleRange = ""
    var referenceListID: UUID?
    var isSearching = false
    var report: LibrarySearchReport?
    var progress: LibrarySearchProgress?
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    func cancel() { generation += 1; task?.cancel(); task = nil; isSearching = false }
    func run(_ resources: [LibraryResource], documents: [StudyDocument] = []) {
        cancel(); let token = generation
        error = nil; report = nil; progress = nil
        let selected = allResources ? resources : resources.filter { $0.id == resourceID }
        guard !selected.isEmpty else { error = L("Selecciona un recurso para buscar."); return }
        do {
            let parsed = try SearchQueryParser.parse(query)
            var options = TextSearchOptions(); options.caseSensitive = caseSensitive; options.wholeWords = wholeWords
            let unit: LibrarySearchUnit = bibleVerses ? .bibleVerse : .article
            let rangeMode = bibleRangeMode, rangeText = customBibleRange
            let list = documents.first { $0.id == referenceListID && $0.kind == .verseList }
            isSearching = true; error = nil; report = nil; progress = nil
            task = Task { [weak self] in
                do {
                    let result = try await Self.execute(resources: selected, query: parsed, options: options, unit: unit,
                        rangeMode: rangeMode, rangeText: rangeText, list: list, onProgress: { [weak self] value in
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
    nonisolated private static func execute(resources: [LibraryResource], query: SearchQuery,
        options: TextSearchOptions, unit: LibrarySearchUnit, rangeMode: WorkspaceBibleRangeMode,
        rangeText: String, list: StudyDocument?,
        onProgress: @escaping @Sendable (LibrarySearchProgress) async -> Void) async throws -> LibrarySearchReport {
        let range: BibleSearchRange?
        if unit == .bibleVerse {
            switch rangeMode {
            case .all: range = nil
            case .custom: range = try BibleSearchRange.parse(rangeText)
            case .savedList:
                guard let list else { throw BibleSearchRangeError.missingReferenceList }
                range = try BibleSearchRange.referenceList(list)
            }
        } else { range = nil }
        return try await LibrarySearchService(provider: PersistentLibrarySearchProvider(source: WorkspaceSearchReader())).search(
            resources: resources, query: query, options: options, unit: unit, bibleRange: range,
            budget: .init(maximumDurationSeconds: 120, maximumArticles: 250_000, maximumResults: 500), onProgress: onProgress)
    }
    private func receive(_ value: LibrarySearchProgress, token: Int) { if generation == token { progress = value } }
}
