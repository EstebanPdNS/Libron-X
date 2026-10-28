import Foundation
import Observation
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
}

/// A guide combines verified source lookups with explicit reference mentions.
/// An unsuccessful or limited scan is never reported as evidence of absence.
@MainActor @Observable final class PassageGuideController {
    typealias Lookup = @Sendable (LibraryResource, KeyLinkScope, String) async throws -> KeyLinkMatch?
    typealias ReferenceLookup = @Sendable ([LibraryResource], BibleReferenceQuery) async throws -> PassageGuideReferences
    var passage = ""
    var terms = ""
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
            _ = try BibleCopyPassage.parse(requested)
            let query = try BibleReferenceQuery.parse(requested)
            let raw = terms.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard raw.count <= 8, raw.allSatisfy({ $0.utf16.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw PersonalStateError.invalid("Introduce hasta ocho palabras de diccionario válidas.")
            }
            var seen = Set<String>()
            let words = raw.filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted }
            let commentary = workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .commentary))
            let dictionaries = workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .dictionary))
            let lexicons = workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .lexicon))
            let sources = workspace.availableResources.filter { !$0.isHelp }
            let token = generation, lookup = lookup, referenceLookup = referenceLookup
            searchedTerms = words; commentaryCount = commentary.count; dictionaryCount = dictionaries.count + lexicons.count; referenceSourceCount = sources.count
            isLoading = true
            task = Task { [weak self, weak workspace] in
                guard let self else { return }
                do {
                    for (kind, resources, items) in [(KeyLinkKind.commentary, commentary, [requested]), (.dictionary, dictionaries, words), (.lexicon, lexicons, words)] {
                        for resource in resources {
                            for term in items {
                                try Task.checkCancellation()
                                self.currentSource = resource.title
                                do {
                                    let found = try await lookup(resource, .init(kind: kind), term)
                                    guard self.generation == token else { return }
                                    guard let workspace, workspace.availableResources.contains(resource) else { throw PersonalStateError.invalid("La biblioteca cambió. Vuelve a generar la guía.") }
                                    if let found, found.resource == resource { self.matches.append(.init(term: term, kind: kind, match: found)) }
                                } catch is CancellationError { throw CancellationError() }
                                catch {
                                    guard self.generation == token else { return }
                                    guard let workspace, workspace.availableResources.contains(resource) else { throw error }
                                    self.failures.append(resource.title + ": " + error.localizedDescription)
                                }
                            }
                        }
                    }
                    self.currentSource = nil
                    let citations = try await referenceLookup(sources, query)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    guard let workspace, workspace.availableResources.filter({ !$0.isHelp }) == sources else { throw PersonalStateError.invalid("La biblioteca cambió. Vuelve a generar la guía.") }
                    self.references = citations; self.completed = true; self.isLoading = false; self.task = nil; self.currentSource = nil
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
    nonisolated private static func findReferences(_ resources: [LibraryResource], _ query: BibleReferenceQuery) async throws -> PassageGuideReferences {
        let service = BibleReferenceSearchService(provider: PersistentLibrarySearchProvider(source: WorkspaceSearchReader()))
        let report = try await service.search(resources: resources, query: query,
            budget: .init(maximumDurationSeconds: 60, maximumArticles: 50_000, maximumResults: 250))
        let warnings = report.resources.filter { $0.status != .complete }.map { $0.resourceTitle + ": " + $0.status.rawValue }
        return .init(results: report.results, complete: report.coverageComplete, warnings: warnings)
    }
    deinit { task?.cancel() }
}
