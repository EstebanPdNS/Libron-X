import Foundation
import Observation
import LibronixCore

enum WorkspaceBibleRangeMode: String, CaseIterable, Sendable { case all, custom, savedList }

@MainActor @Observable final class WorkspaceSearchController {
    var query = ""
    var searchField: SearchField?
    var approximatePhrase = false
    var maximumEdits = 1
    var scope = WorkspaceSearchScopeSelection()
    var resourceID: String? { get { scope.resourceID } set { scope.resourceID = newValue } }
    var allResources: Bool { get { scope.allResources } set { scope.allResources = newValue } }
    private(set) var scopeSnapshot: WorkspaceSearchScopeSnapshot?
    var coverageComplete: Bool { report?.coverageComplete == true && scopeSnapshot?.complete != false }
    var caseSensitive = false
    var wholeWords = true
    var bibleVerses = false
    var bibleRangeMode = WorkspaceBibleRangeMode.all
    var customBibleRange = ""
    var referenceListID: UUID?
    var isSearching = false
    let presentation = WorkspaceSearchResultsController()
    var report: LibrarySearchReport? { didSet { presentation.setResults(report?.results ?? []) } }
    var progress: LibrarySearchProgress?
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    func cancel() { generation += 1; task?.cancel(); task = nil; isSearching = false }
    func clear() { cancel(); error = nil; report = nil; progress = nil; scopeSnapshot = nil }
    func run(_ resources: [LibraryResource], documents: [StudyDocument] = [], scopeContext: WorkspaceSearchScopeContext? = nil) {
        clear(); let token = generation
        do {
            let snapshot = try WorkspaceSearchScopeResolver.resolve(scope, context: scopeContext ?? .init(library: resources))
            scopeSnapshot = snapshot
            let selected = snapshot.resources
            guard !selected.isEmpty else { throw WorkspaceSearchScopeError.noResources }
            let text: String
            if approximatePhrase {
                // Treat the complete entry literally, including quotes/operators.
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                text = "\"" + escaped + "\""
            } else { text = query }
            let compiled = searchField.map { $0.rawValue + ":(" + text + ")" } ?? text
            let parsed = try SearchQueryParser.parse(compiled, limits: .init(maximumOperandUTF16: approximatePhrase ? 16_384 : 512))
            var options = TextSearchOptions(); options.caseSensitive = caseSensitive; options.wholeWords = wholeWords
            options.maximumEditDistance = approximatePhrase ? maximumEdits : 0
            if approximatePhrase { options.maximumMatchAttempts = 5_000_000 }
            // Validate query/options before starting any asynchronous source work.
            _ = try TextSearchEngine.search(query: parsed, in: "", options: options,
                verses: parsed.expression.requiresVerseContext ? [] : nil,
                fields: .init(regions: Dictionary(uniqueKeysWithValues: parsed.expression.requiredFields.map { ($0, []) })))
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
