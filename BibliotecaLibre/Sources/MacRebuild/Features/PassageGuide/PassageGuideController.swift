import Foundation
import Observation
import NaturalLanguage
import LibronixCore

struct PassageGuideMatch: Identifiable, Sendable {
    let term: String
    let kind: KeyLinkKind
    let match: KeyLinkMatch
    var id: String { kind.rawValue + ":" + term + ":" + match.resource.id }
}
struct PassageGuideReferences: Sendable {
    let results: [BibleReferenceSearchResult]
    let complete: Bool
    let warnings: [String]
    var resources: [PassageGuideResourceWarning] = []
}
struct PassageGuideResourceWarning: Sendable, Identifiable {
    let id: String
    let title: String
    let status: LibrarySearchResourceStatus
    let details: [String]
    var statusKey: String {
        switch status {
        case .complete: return "Búsqueda completa"
        case .partial: return "Búsqueda parcial"
        case .incompatible: return "Recurso incompatible"
        case .failed: return "No se pudo buscar el recurso"
        case .notExamined: return "Recurso no examinado"
        }
    }
}

/// A guide combines verified source lookups with explicit reference mentions.
/// An unsuccessful or limited scan is never reported as evidence of absence.
@MainActor @Observable final class PassageGuideController {
    typealias Lookup = @Sendable (LibraryResource, KeyLinkScope, String) async throws -> KeyLinkMatch?
    typealias ReferenceLookup = @Sendable ([LibraryResource], BibleReferenceQuery) async throws -> PassageGuideReferences
    var passage = ""
    var terms = ""
    /// Reference scanning can be restricted without changing commentary or dictionary priorities.
    var referenceResourceID: String?
    private(set) var matches: [PassageGuideMatch] = []
    private(set) var references: PassageGuideReferences?
    private(set) var failures: [String] = []
    private(set) var searchedTerms: [String] = []
    private(set) var commentaryCount = 0
    private(set) var dictionaryCount = 0
    private(set) var referenceSourceCount = 0
    private(set) var isLoading = false
    private(set) var completed = false
    private(set) var error: String?
    func showOpeningError(_ message: String) { error = message }
    private(set) var currentSource: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let lookup: Lookup
    @ObservationIgnored private let referenceLookup: ReferenceLookup
    init(lookup: @escaping Lookup = KeyLinkController.resolve, referenceLookup: @escaping ReferenceLookup = PassageGuideController.findReferences) {
        self.lookup = lookup; self.referenceLookup = referenceLookup
    }
    func clear() {
        generation += 1; task?.cancel(); task = nil; isLoading = false; completed = false
        matches = []; references = nil; failures = []; searchedTerms = []; commentaryCount = 0; dictionaryCount = 0; referenceSourceCount = 0; error = nil; currentSource = nil
    }
    func run(workspace: StudyWorkspace) {
        clear()
        do {
            let requested = passage.trimmingCharacters(in: .whitespacesAndNewlines)
            let passage = try BibleCopyPassage.parse(requested)
            let query = try BibleReferenceQuery.parse(requested)
            let raw = terms.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard raw.count <= 8, raw.allSatisfy({ $0.utf16.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw PersonalStateError.invalid("Introduce hasta ocho palabras de diccionario válidas.")
            }
            var seen = Set<String>()
            let words = raw.filter { seen.insert(LibronDictionaryIndex.key($0)).inserted }
            let commentary = workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .commentary))
            let dictionaries = workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .dictionary))
            let lexicons = workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .lexicon))
            let bibles = workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .bible))
                .filter { [.legacyLSF, .eSwordSQLite, .libronixLLS].contains($0.format) }
            let library = workspace.availableResources.filter { !$0.isHelp }
            let sources = referenceResourceID.map { id in library.filter { $0.id == id } } ?? library
            if referenceResourceID != nil && sources.count != 1 { throw PersonalStateError.invalid("El recurso seleccionado ya no está disponible.") }
            let token = generation, lookup = lookup, referenceLookup = referenceLookup
            searchedTerms = words; commentaryCount = commentary.count; dictionaryCount = dictionaries.count + lexicons.count; referenceSourceCount = sources.count
            isLoading = true
            task = Task { [weak self, weak workspace] in
                guard let self else { return }
                do {
                    guard let workspace else { throw PersonalStateError.invalid("La biblioteca cambió. Vuelve a generar la guía.") }
                    async let referencesTask: Void = self.collectReferences(workspace: workspace, library: library, sources: sources, query: query, token: token, referenceLookup: referenceLookup)
                    var searchWords = words
                    if searchWords.isEmpty, !dictionaries.isEmpty || !lexicons.isEmpty, let bible = bibles.first {
                        do {
                            let document = try await WorkspaceBibleCopy.prepare(bible, passage: passage, includeFootnotes: false)
                            let text = document.verses.map(\.text).joined(separator: " ")
                            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
                            var keys = Set<String>()
                            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                                let word = String(text[range]), key = LibronDictionaryIndex.key(word)
                                if word.count >= 4, word.utf16.count <= 128, keys.insert(key).inserted { searchWords.append(word) }
                                return searchWords.count < 8
                            }
                            try Task.checkCancellation()
                            guard self.generation == token else { throw CancellationError() }
                            self.searchedTerms = searchWords
                        } catch is CancellationError { throw CancellationError() }
                        catch { self.failures.append(bible.title + ": " + error.localizedDescription) }
                    }
                    for (kind, resources, items) in [(KeyLinkKind.commentary, commentary, [requested]), (.dictionary, dictionaries, searchWords), (.lexicon, lexicons, searchWords)] {
                        for resource in resources {
                            for term in items {
                                try Task.checkCancellation()
                                self.currentSource = resource.title
                                do {
                                    let found = try await lookup(resource, .init(kind: kind), term)
                                    guard self.generation == token else { return }
                                    guard workspace.availableResources.contains(resource) else { throw PersonalStateError.invalid("La biblioteca cambió. Vuelve a generar la guía.") }
                                    if let found, found.resource == resource { self.matches.append(.init(term: term, kind: kind, match: found)) }
                                } catch is CancellationError { throw CancellationError() }
                                catch {
                                    guard self.generation == token else { return }
                                    guard workspace.availableResources.contains(resource) else { throw error }
                                    self.failures.append(resource.title + ": " + error.localizedDescription)
                                }
                            }
                        }
                    }
                    self.currentSource = nil
                    try await referencesTask
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    guard workspace.availableResources.filter({ !$0.isHelp }) == library else { throw PersonalStateError.invalid("La biblioteca cambió. Vuelve a generar la guía.") }
                    self.completed = true; self.isLoading = false; self.task = nil; self.currentSource = nil
                } catch is CancellationError {
                    if self.generation == token { self.isLoading = false; self.task = nil; self.currentSource = nil }
                }
                catch {
                    guard self.generation == token else { return }
                    self.error = error.localizedDescription; self.isLoading = false; self.task = nil; self.currentSource = nil
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func collectReferences(workspace: StudyWorkspace, library: [LibraryResource], sources: [LibraryResource], query: BibleReferenceQuery,
                                   token: Int, referenceLookup: ReferenceLookup) async throws {
        let citations = try await referenceLookup(sources, query)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard workspace.availableResources.filter({ !$0.isHelp }) == library else { throw PersonalStateError.invalid("La biblioteca cambió. Vuelve a generar la guía.") }
        references = citations
    }
    nonisolated static func findReferences(_ resources: [LibraryResource], _ query: BibleReferenceQuery) async throws -> PassageGuideReferences {
        let service = BibleReferenceSearchService(provider: PersistentLibrarySearchProvider(source: WorkspaceSearchReader()))
        let report = try await service.search(resources: resources, query: query,
            budget: .init(maximumDurationSeconds: 60, maximumArticles: 50_000, maximumResults: 250))
        let resources = report.resources.filter { $0.status != .complete }.map {
            PassageGuideResourceWarning(id: $0.resourceID, title: $0.resourceTitle, status: $0.status,
                                        details: $0.warnings + $0.errors.map(\.message))
        }
        return .init(results: report.results, complete: report.coverageComplete, warnings: [], resources: resources)
    }
    deinit { task?.cancel() }
}
