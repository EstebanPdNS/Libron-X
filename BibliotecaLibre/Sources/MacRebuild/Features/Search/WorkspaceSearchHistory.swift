import Foundation
import LibronixCore
import Observation

/// A search configuration is retained independently of search results, so replay
/// always resolves the current library and reports resources that disappeared.
struct WorkspaceSearchConfiguration: Codable, Equatable {
    var query: String
    var field: SearchField?
    var approximatePhrase: Bool
    var maximumEdits: Int
    var scopeKind: WorkspaceSearchScopeKind
    var resourceID: String?
    var collectionIDs: Set<UUID>
    var subsetMembers: [LibraryCollectionMember]
    var unresolvedSubsetIDs: Set<String>
    var caseSensitive: Bool
    var wholeWords: Bool
    var bibleVerses: Bool
    var bibleRangeMode: WorkspaceBibleRangeMode
    var customBibleRange: String
    var referenceListID: UUID?
    var limits: WorkspaceSearchLimits
    var wordFilter: SearchWordFilter? = nil
    var excludedRange: WorkspaceExcludedBibleRange? = nil
    var namedRangeID: UUID? = nil

    func validate() throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf16.count <= 16_384, !query.contains("\0"),
              (1...3).contains(maximumEdits), customBibleRange.utf16.count <= 16_384,
              !customBibleRange.contains("\0"), collectionIDs.count <= 256,
              subsetMembers.count <= 8_192, unresolvedSubsetIDs.count <= 8_192,
              Set(subsetMembers.map(\.id)).count == subsetMembers.count,
              Set(subsetMembers.map(\.id)).isDisjoint(with: unresolvedSubsetIDs),
              ([resourceID].compactMap { $0 } + Array(unresolvedSubsetIDs) + subsetMembers.map(\.resourceID))
                .allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 16_384 }),
              subsetMembers.allSatisfy({ $0.title.utf8.count <= 4096 && ($0.legacyIdentifier?.utf8.count ?? 0) <= 1024 })
        else { throw PersonalStateError.invalid("El historial de búsquedas contiene datos incompatibles.") }
        try limits.budget.validate()
        if let excludedRange {
            guard excludedRange.customRange.utf16.count <= 16_384, !excludedRange.customRange.contains("\0") else {
                throw PersonalStateError.invalid("El historial de búsquedas contiene datos incompatibles.")
            }
        }
        if let wordFilter { _ = try wordFilter.compile(query) }
    }
}
struct WorkspaceSearchHistoryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var configuration: WorkspaceSearchConfiguration
}
struct WorkspaceSearchHistorySnapshot: Codable, Equatable {
    var schemaVersion = 1
    var entries: [WorkspaceSearchHistoryEntry] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard entries.count <= 100, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.date.timeIntervalSinceReferenceDate.isFinite }) else {
            throw PersonalStateError.invalid("El historial de búsquedas contiene datos incompatibles.")
        }
        for entry in entries { try entry.configuration.validate() }
    }
}
@MainActor @Observable final class WorkspaceSearchHistory {
    private(set) var entries: [WorkspaceSearchHistoryEntry] = []
    private(set) var loadError: String?
    @ObservationIgnored private let file: PersonalStateFile<WorkspaceSearchHistorySnapshot>
    @ObservationIgnored private var writable = false
    init(url: URL? = nil) {
        let path = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/search-history.json")
        file = PersonalStateFile(url: path)
        do {
            if let snapshot = try file.load() { try snapshot.validate(); entries = snapshot.entries }
            writable = true
        } catch { loadError = error.localizedDescription }
    }
    func record(_ configuration: WorkspaceSearchConfiguration) throws {
        try configuration.validate()
        var next = entries.filter { $0.configuration != configuration }
        next.insert(.init(configuration: configuration), at: 0)
        try replace(Array(next.prefix(100)))
    }
    func remove(_ id: UUID) throws { try replace(entries.filter { $0.id != id }) }
    func clear() throws { try replace([]) }
    private func replace(_ next: [WorkspaceSearchHistoryEntry]) throws {
        guard writable else { throw PersonalStateError.invalid(loadError ?? "No se pudo abrir el historial de búsquedas.") }
        guard next != entries else { return }
        let snapshot = WorkspaceSearchHistorySnapshot(entries: next)
        try snapshot.validate(); try file.save(snapshot); entries = next
    }
}
