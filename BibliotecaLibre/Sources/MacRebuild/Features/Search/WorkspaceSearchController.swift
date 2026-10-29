import Foundation
import Observation
import LibronixCore

enum WorkspaceBibleRangeMode: String, Codable, CaseIterable, Sendable { case all, custom, savedList }
enum WorkspaceSearchPhase: Equatable { case idle, running, pausing, paused, cancelling, cancelled, finished, failed }
struct WorkspaceSearchLimits: Codable, Hashable, Sendable {
    var durationSeconds = 120.0
    var articles = 250_000
    var results = 500
    var occurrences = 20_000
    var budget: LibrarySearchBudget { .init(maximumDurationSeconds: durationSeconds, maximumArticles: articles,
        maximumResults: results, maximumOccurrences: occurrences, progressBatchSize: 16) }
}

@MainActor @Observable final class WorkspaceSearchController {
    var query = ""
    var searchField: SearchField?
    var approximatePhrase = false
    var maximumEdits = 1
    var scope = WorkspaceSearchScopeSelection()
    var resourceID: String? { get { scope.resourceID } set { scope.resourceID = newValue } }
    var allResources: Bool { get { scope.allResources } set { scope.allResources = newValue } }
    private(set) var scopeSnapshot: WorkspaceSearchScopeSnapshot?
    var coverageComplete: Bool { report?.runState == .finished && report?.coverageComplete == true && scopeSnapshot?.complete != false && !configurationChanged }
    var caseSensitive = false
    var wholeWords = true
    var bibleVerses = false
    var bibleRangeMode = WorkspaceBibleRangeMode.all
    var customBibleRange = ""
    var referenceListID: UUID?
    var limits = WorkspaceSearchLimits()
    private(set) var phase = WorkspaceSearchPhase.idle
    var isSearching: Bool { [.running,.pausing,.paused,.cancelling].contains(phase) }
    let presentation = WorkspaceSearchResultsController()
    var report: LibrarySearchReport? { didSet { presentation.setResults(report?.results ?? [], preserveSelection: oldValue != nil) } }
    var progress: LibrarySearchProgress?
    var error: String?
    var historyError: String?
    var history: WorkspaceSearchHistory?
    private(set) var submittedQuery: String?
    var configurationChanged: Bool { report != nil && submittedIdentity.map { $0 != identity } == true }
    var canOpenResults: Bool { report != nil && report?.runState != .failed && !configurationChanged && phase != .cancelling }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var control: LibrarySearchControl?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let providerFactory: @Sendable () -> any LibrarySearchContentProvider
    private var submittedIdentity: Identity?
    private struct Identity: Hashable {
        let query: String; let field: SearchField?; let approximate: Bool; let edits: Int
        let caseSensitive: Bool; let wholeWords: Bool; let verses: Bool
        let rangeMode: String; let range: String; let list: UUID?
        let scope: String; let resource: String?; let collections: Set<UUID>; let subset: Set<String>
        let limits: WorkspaceSearchLimits
    }
    private var identity: Identity {
        .init(query: query, field: searchField, approximate: approximatePhrase, edits: approximatePhrase ? maximumEdits : 0,
              caseSensitive: caseSensitive, wholeWords: wholeWords, verses: bibleVerses,
              rangeMode: bibleVerses ? bibleRangeMode.rawValue : "", range: bibleVerses && bibleRangeMode == .custom ? customBibleRange : "",
              list: bibleVerses && bibleRangeMode == .savedList ? referenceListID : nil,
              scope: scope.kind.rawValue, resource: scope.kind == .resource ? resourceID : nil,
              collections: scope.kind == .collections ? scope.collectionIDs : [], subset: scope.kind == .subset ? scope.selectedSubsetIDs : [], limits: limits)
    }
    init(providerFactory: @escaping @Sendable () -> any LibrarySearchContentProvider = { PersistentLibrarySearchProvider(source: WorkspaceSearchReader()) }) {
        self.providerFactory = providerFactory
    }
    deinit { task?.cancel() }
    var historyConfiguration: WorkspaceSearchConfiguration {
        .init(query: query, field: searchField, approximatePhrase: approximatePhrase, maximumEdits: maximumEdits,
              scopeKind: scope.kind, resourceID: resourceID, collectionIDs: scope.collectionIDs,
              subsetMembers: scope.members, unresolvedSubsetIDs: scope.unresolvedSubsetIDs,
              caseSensitive: caseSensitive, wholeWords: wholeWords, bibleVerses: bibleVerses,
              bibleRangeMode: bibleRangeMode, customBibleRange: customBibleRange, referenceListID: referenceListID,
              limits: limits)
    }
    func restore(_ configuration: WorkspaceSearchConfiguration) throws {
        guard !isSearching else { throw PersonalStateError.invalid("Cancela la búsqueda antes de cambiar su configuración.") }
        try configuration.validate()
        clear()
        query = configuration.query; searchField = configuration.field
        approximatePhrase = configuration.approximatePhrase; maximumEdits = configuration.maximumEdits
        scope.kind = configuration.scopeKind; resourceID = configuration.resourceID
        scope.collectionIDs = configuration.collectionIDs
        scope.restoreSubset(members: configuration.subsetMembers, unresolvedIDs: configuration.unresolvedSubsetIDs)
        caseSensitive = configuration.caseSensitive; wholeWords = configuration.wholeWords
        bibleVerses = configuration.bibleVerses; bibleRangeMode = configuration.bibleRangeMode
        customBibleRange = configuration.customBibleRange; referenceListID = configuration.referenceListID
        limits = configuration.limits
    }
    func pause() {
        guard phase == .running, let control else { return }
        phase = .pausing
        Task { await control.pause() }
    }
    func resume() {
        guard phase == .paused, let control else { return }
        guard !configurationChanged else { error = L("La configuración cambió. Cancela e inicia una búsqueda nueva."); return }
        error = nil; phase = .running
        Task { await control.resume() }
    }
    func cancel() {
        guard isSearching, phase != .cancelling else { return }
        phase = .cancelling
        let gate = control, job = task
        Task { await gate?.cancel(); job?.cancel() }
    }
    func clear() {
        generation += 1; task?.cancel(); task = nil
        let abandoned = control; control = nil
        Task { await abandoned?.cancel() }
        phase = .idle; error = nil; report = nil; progress = nil; scopeSnapshot = nil; submittedIdentity = nil; submittedQuery = nil
    }
    func run(_ resources: [LibraryResource], documents: [StudyDocument] = [], scopeContext: WorkspaceSearchScopeContext? = nil) {
        clear(); let token = generation
        do {
            let snapshot = try WorkspaceSearchScopeResolver.resolve(scope, context: scopeContext ?? .init(library: resources))
            scopeSnapshot = snapshot
            let selected = snapshot.resources
            guard !selected.isEmpty else { throw WorkspaceSearchScopeError.noResources }
            let text: String
            if approximatePhrase {
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                text = "\"" + escaped + "\""
            } else { text = query }
            let compiled = searchField.map { $0.rawValue + ":(" + text + ")" } ?? text
            let parsed = try SearchQueryParser.parse(compiled, limits: .init(maximumOperandUTF16: approximatePhrase ? 16_384 : 512))
            var options = TextSearchOptions(); options.caseSensitive = caseSensitive; options.wholeWords = wholeWords
            options.maximumEditDistance = approximatePhrase ? maximumEdits : 0
            if approximatePhrase { options.maximumMatchAttempts = 5_000_000 }
            _ = try TextSearchEngine.search(query: parsed, in: "", options: options,
                verses: parsed.expression.requiresVerseContext ? [] : nil,
                fields: .init(regions: Dictionary(uniqueKeysWithValues: parsed.expression.requiredFields.map { ($0, []) })))
            let budget = limits.budget; try budget.validate()
            let unit: LibrarySearchUnit = bibleVerses ? .bibleVerse : .article
            let range: BibleSearchRange?
            if unit == .bibleVerse {
                switch bibleRangeMode {
                case .all: range = nil
                case .custom: range = try BibleSearchRange.parse(customBibleRange)
                case .savedList:
                    guard let list = documents.first(where: { $0.id == referenceListID && $0.kind == .verseList }) else { throw BibleSearchRangeError.missingReferenceList }
                    range = try BibleSearchRange.referenceList(list)
                }
            } else { range = nil }
            let control = LibrarySearchControl(), provider = providerFactory()
            self.control = control; submittedIdentity = identity; submittedQuery = query; phase = .running
            if let history {
                do { try history.record(historyConfiguration); historyError = nil }
                catch { historyError = error.localizedDescription }
            }
            task = Task { [weak self] in
                do {
                    let result = try await LibrarySearchService(provider: provider).search(resources: selected, query: parsed, options: options,
                        unit: unit, bibleRange: range, budget: budget, control: control,
                        onSnapshot: { [weak self] value in await self?.receive(value, token: token) },
                        onProgress: { [weak self] value in await self?.receive(value, token: token) })
                    guard let self, token == self.generation, !Task.isCancelled else { return }
                    self.report = result; self.phase = .finished; self.task = nil; self.control = nil
                } catch {
                    guard let self, token == self.generation else { return }
                    if error is CancellationError { self.phase = .cancelled }
                    else {
                        self.phase = .failed
                        self.error = (error as? LibrarySearchError) == .resumeSourceChanged
                            ? L("Una fuente cambió o no pudo verificarse después de la pausa. Inicia una búsqueda nueva.") : error.localizedDescription
                    }
                    self.task = nil; self.control = nil
                }
            }
        } catch { phase = .failed; self.error = error.localizedDescription }
    }
    private func receive(_ value: LibrarySearchProgress, token: Int) { if generation == token { progress = value } }
    private func receive(_ value: LibrarySearchReport, token: Int) {
        guard generation == token else { return }
        report = value
        if phase == .cancelling, value.runState == .running || value.runState == .paused { return }
        if phase == .pausing, value.runState == .running { return }
        switch value.runState {
        case .running: phase = .running
        case .paused: phase = .paused
        case .cancelled: phase = .cancelled
        case .finished: phase = .finished
        case .failed: phase = .failed
        }
    }
}
