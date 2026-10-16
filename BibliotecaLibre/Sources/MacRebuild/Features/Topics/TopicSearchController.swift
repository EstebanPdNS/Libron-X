import Foundation
import Observation
import LibronixCore

struct TopicEntry: Identifiable, Sendable {
    let resource: LibraryResource
    let entry: LegacyArticleDirectoryEntry
    var id: String { resource.id + "#" + String(entry.id) }
}
struct TopicSourceFailure: Identifiable, Sendable {
    let resource: LibraryResource
    let message: String
    var id: String { resource.id }
}
enum TopicSearchMode: String, CaseIterable { case associated, titles }
struct AssociatedTopicEntry: Identifiable, Sendable {
    let resource: LibraryResource
    let index: Int
    let topic: Int
    let indexName: String
    let text: String
    let stamp: LegacyGraphicSourceStamp
    var id: String { resource.id + "#topic#" + String(index) + "#" + String(topic) }
}

/// Presentation grouping never replaces the original key, index, source stamp
/// or resource identity. Case-equivalent display terms share their articles;
/// accents and named indexes remain distinct. Windows collation is not assumed.
struct AssociatedTopicGroup: Identifiable, Sendable {
    let members: [AssociatedTopicEntry]
    private init(members: [AssociatedTopicEntry]) { self.members = members }
    var id: String { members[0].id }
    var text: String { members[0].text }
    var indexName: String { members[0].indexName }
    var resourceCount: Int { Set(members.map(\.resource.id)).count }

    private struct Key: Hashable {
        let index: [UInt16]
        let term: String
    }
    static func grouping(_ entries: [AssociatedTopicEntry]) -> [Self] {
        let locale = Locale(identifier: "en_US_POSIX")
        var positions: [Key: Int] = [:], groups: [[AssociatedTopicEntry]] = []
        for entry in entries {
            let key = Key(index: Array(entry.indexName.utf16),
                term: entry.text.folding(options: .caseInsensitive, locale: locale).precomposedStringWithCanonicalMapping)
            if let position = positions[key] { groups[position].append(entry) }
            else { positions[key] = groups.count; groups.append([entry]) }
        }
        return groups.map { Self(members: $0) }.sorted { left, right in
            let order = left.text.compare(right.text, options: .caseInsensitive, locale: locale)
            if order != .orderedSame { return order == .orderedAscending }
            return Array(left.indexName.utf16).lexicographicallyPrecedes(Array(right.indexName.utf16))
        }
    }
}

/// Resolve scopes against the current visible library, never a stale resource
/// captured when the browser opened. A removed/hidden selection stays empty.
enum TopicResourceScope: Hashable {
    case library
    case resource(String)
    func resources(in visible: [LibraryResource]) -> [LibraryResource] {
        visible.filter { value in
            guard TopicDirectorySource.supports(value) else { return false }
            switch self {
            case .library: return true
            case let .resource(id): return value.id == id
            }
        }
    }
}

/// Read the same checked directory for standalone LSF and embedded Libronix
/// text. The temporary prepared file never becomes a user-visible resource ID.
actor TopicDirectorySource {
    static let shared = TopicDirectorySource()
    private let content = LegacyContentService()
    nonisolated static func supports(_ resource: LibraryResource) -> Bool {
        resource.format == .legacyLSF || resource.format == .libronixLLS
    }
    func directory(_ resource: LibraryResource) async throws -> [LegacyArticleDirectoryEntry] {
        try Task.checkCancellation()
        guard Self.supports(resource) else { throw RebuildError.unsupportedFormat }
        let before = try LegacyGraphicsService.fileStamp(resource.location)
        let embedded = resource.format == .libronixLLS
        let source = embedded ? try await LibronixBookService.shared.prepare(resource) : resource
        let result = try await content.directory(source.location, indexURL: source.indexLocation,
            allowUnavailableIndexBlocks: embedded)
        try Task.checkCancellation()
        guard try LegacyGraphicsService.fileStamp(resource.location) == before else { throw LibronixBookError.sourceChanged }
        return result.entries
    }
    /// Title matching can examine large original directories. Keep it off the
    /// UI actor and retain only enough matches to establish the result limit.
    func matchingEntries(_ entries: [LegacyArticleDirectoryEntry], query: String,
                         maximum: Int) throws -> [LegacyArticleDirectoryEntry] {
        var result: [LegacyArticleDirectoryEntry] = []
        for entry in entries {
            try Task.checkCancellation()
            if entry.displayTitle.localizedStandardContains(query) {
                result.append(entry)
                if result.count >= maximum { break }
            }
        }
        return result
    }
}

enum TopicSearchStatus: Equatable {
    case idle, searching, canceled, libraryChanged
    case finished(matches: Int, unavailable: Int, limited: Bool)
    func message(language: AppLanguage, maximumResults: Int) -> String {
        switch self {
        case .idle: return ""
        case .searching: return AppStrings.text("Buscando…", language: language)
        case .canceled: return AppStrings.text("Búsqueda cancelada.", language: language)
        case .libraryChanged: return AppStrings.text("La biblioteca cambió. Vuelve a buscar.", language: language)
        case let .finished(matches, unavailable, limited):
            var parts = [AppStrings.format("{count} entradas", language: language, values: ["count": String(matches)])]
            if limited { parts.append(AppStrings.format("Se muestran las primeras {count} entradas; quedan resultados o recursos por consultar.",
                language: language, values: ["count": String(maximumResults)])) }
            if unavailable > 0 { parts.append(AppStrings.format("{count} recursos no disponibles", language: language, values: ["count": String(unavailable)])) }
            return parts.joined(separator: " · ")
        }
    }
}

@MainActor @Observable final class TopicSearchController {
    typealias Loader = @Sendable (LibraryResource) async throws -> [LegacyArticleDirectoryEntry]
    typealias TopicLoader = @Sendable (LibraryResource) async throws -> LibronixTopicCatalog?
    private(set) var entries: [TopicEntry] = []
    private(set) var topics: [AssociatedTopicEntry] = []
    private(set) var topicGroups: [AssociatedTopicGroup] = []
    private(set) var selectedTopicID: String?
    private(set) var selectedTopicGroupID: String?
    private(set) var topicResultsLimited = false
    private(set) var failures: [TopicSourceFailure] = []
    private(set) var status: TopicSearchStatus = .idle
    private(set) var isLoading = false
    let maximumResults: Int
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let topicLoader: TopicLoader
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    init(maximumResults: Int = 500, loader: @escaping Loader = { try await TopicDirectorySource.shared.directory($0) }) {
        self.maximumResults = max(1, min(500, maximumResults)); self.loader = loader
        self.topicLoader = { try await LibronixTopicCatalogService.shared.catalog($0) }
    }
    init(maximumResults: Int = 500, topicLoader: @escaping TopicLoader, directoryLoader: @escaping Loader) {
        self.maximumResults = max(1, min(500, maximumResults)); self.loader = directoryLoader; self.topicLoader = topicLoader
    }
    deinit { task?.cancel() }
    func cancel() {
        generation += 1; task?.cancel(); task = nil
        if isLoading { status = .canceled }
        isLoading = false
    }
    func libraryDidChange() {
        cancel(); entries = []; topics = []; topicGroups = []; selectedTopicID = nil; selectedTopicGroupID = nil; topicResultsLimited = false; failures = []; status = .libraryChanged
    }
    func search(_ query: String, resources: [LibraryResource], mode: TopicSearchMode = .titles) {
        cancel(); entries = []; topics = []; topicGroups = []; selectedTopicID = nil; selectedTopicGroupID = nil; topicResultsLimited = false; failures = []; status = .idle
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        if mode == .associated { searchAssociated(needle, resources:resources); return }
        let sources = resources.filter(TopicDirectorySource.supports), token = generation
        let load = loader, limit = maximumResults
        isLoading = true; status = .searching
        task = Task { [weak self] in
            var found: [TopicEntry] = [], failed: [TopicSourceFailure] = [], limited = false
            for (index, resource) in sources.enumerated() {
                guard !Task.isCancelled else { return }
                do {
                    let directory = try await load(resource)
                    guard !Task.isCancelled else { return }
                    let capacity = limit - found.count
                    let matches = try await TopicDirectorySource.shared.matchingEntries(directory, query: needle, maximum: capacity + 1)
                    guard !Task.isCancelled else { return }
                    found += matches.prefix(capacity).map { TopicEntry(resource: resource, entry: $0) }
                    if matches.count > capacity || (found.count == limit && index + 1 < sources.count) {
                        limited = true; break
                    }
                } catch is CancellationError {
                    if let self, token == self.generation {
                        self.isLoading = false; self.task = nil; self.status = .canceled
                    }
                    return
                }
                catch { failed.append(.init(resource: resource, message: error.localizedDescription)) }
            }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.entries = found; self.failures = failed
            self.isLoading = false; self.task = nil
            self.status = .finished(matches: found.count, unavailable: failed.count, limited: limited)
        }
    }

    private func searchAssociated(_ prefix: String, resources: [LibraryResource]) {
        let token = generation, load = topicLoader, limit = maximumResults
        let sources = resources.filter { $0.format == .libronixLLS }
        isLoading = true; status = .searching
        task = Task { [weak self] in
            var found: [AssociatedTopicEntry] = [], failed: [TopicSourceFailure] = [], limited = false
            for (ordinal, resource) in sources.enumerated() {
                guard !Task.isCancelled else { return }
                do {
                    guard let catalog = try await load(resource) else { continue }
                    let capacity = limit - found.count
                    let matches = try await LibronixTopicCatalogService.shared.matching(catalog,prefix:prefix,maximum:capacity+1)
                    guard !Task.isCancelled else { return }
                    found += matches.prefix(capacity).map { match in
                        .init(resource:resource,index:match.index,topic:match.topic,
                            indexName:catalog.indexes[match.index].name,text:catalog.indexes[match.index].topics[match.topic].text,stamp:catalog.sourceStamp)
                    }
                    if matches.count > capacity || (found.count == limit && ordinal+1 < sources.count) { limited = true; break }
                } catch is CancellationError {
                    guard let self, token == self.generation else { return }
                    self.isLoading = false; self.task = nil; self.status = .canceled; return
                } catch { failed.append(.init(resource:resource,message:error.localizedDescription)) }
            }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.topics = found; self.topicGroups = AssociatedTopicGroup.grouping(found)
            self.topicResultsLimited = limited
            self.failures = failed; self.isLoading = false; self.task = nil
            self.status = .finished(matches:self.topicGroups.count,unavailable:failed.count,limited:limited)
        }
    }

    func selectTopic(_ id: String?) {
        if id == nil { clearSelection(); return }
        guard let item = topics.first(where: { $0.id == id }) else { return }
        select([item], topicID: item.id, groupID: nil)
    }

    func selectTopicGroup(_ id: String?) {
        if id == nil { clearSelection(); return }
        guard let group = topicGroups.first(where: { $0.id == id }) else { return }
        select(group.members, topicID: nil, groupID: group.id)
    }

    private func clearSelection() {
        cancel(); selectedTopicID = nil; selectedTopicGroupID = nil; entries = []; status = .idle
    }

    private func select(_ members: [AssociatedTopicEntry], topicID: String?, groupID: String?) {
        cancel(); entries = []; selectedTopicID = topicID; selectedTopicGroupID = groupID
        let token = generation, load = topicLoader
        let previousFailures = failures
        isLoading = true; status = .searching
        task = Task { [weak self] in
            var found: [TopicEntry] = [], failed = previousFailures
            var checked = Set<String>(), unavailable = Set<String>()
            var lastResource: String?, lastCatalog: LibronixTopicCatalog?
            do {
                for item in members {
                    try Task.checkCancellation()
                    if unavailable.contains(item.resource.id) { continue }
                    do {
                        let catalog: LibronixTopicCatalog
                        if lastResource == item.resource.id, let cached = lastCatalog { catalog = cached }
                        else {
                            guard let loaded = try await load(item.resource) else { throw LibronixBookError.sourceChanged }
                            catalog = loaded; lastCatalog = loaded; lastResource = item.resource.id
                        }
                        guard catalog.sourceStamp == item.stamp,
                      catalog.indexes.indices.contains(item.index),
                      catalog.indexes[item.index].topics.indices.contains(item.topic),
                      Array(catalog.indexes[item.index].topics[item.topic].text.utf16) == Array(item.text.utf16),
                      catalog.indexes[item.index].name == item.indexName else { throw LibronixBookError.sourceChanged }
                        for article in try await LibronixTopicCatalogService.shared.articles(catalog,index:item.index,topic:item.topic) {
                            try Task.checkCancellation()
                            let identity = item.resource.id + "#physical#" + String(article.sectionOrdinal)
                            if checked.insert(identity).inserted { found.append(.init(resource:item.resource,entry:article)) }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // A changed member must not hide valid articles from a
                        // different original resource in the same display group.
                        unavailable.insert(item.resource.id)
                        found.removeAll { $0.resource.id == item.resource.id }
                        failed.removeAll { $0.id == item.resource.id }
                        failed.append(.init(resource:item.resource,message:error.localizedDescription))
                    }
                }
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.entries = found; self.failures = failed
                self.isLoading = false; self.task = nil
                self.status = .finished(matches:found.count,unavailable:failed.count,limited:false)
            } catch {
                // Per-source errors are handled above; only cancellation can
                // terminate the outer sequence without publishing its results.
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.isLoading = false; self.task = nil; self.status = .canceled
            }
        }
    }
}
