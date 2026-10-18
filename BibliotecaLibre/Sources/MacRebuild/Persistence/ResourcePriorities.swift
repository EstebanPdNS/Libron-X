import Foundation
import Observation
import LibronixCore

enum KeyLinkKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bible, commentary, dictionary, lexicon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bible: "Biblia"
        case .commentary: "Comentario bíblico"
        case .dictionary: "Diccionario"
        case .lexicon: "Léxico"
        }
    }
    func supports(_ resource: LibraryResource) -> Bool {
        guard !resource.isHelp, resource.format != .logosModern, resource.support != .invalidFile else { return false }
        let type = LibronMetadata.deriving(resource).resourceType
        switch self {
        case .bible: return type == "Biblia"
        case .commentary: return type == "Comentario bíblico"
        case .dictionary: return type == "Diccionario o enciclopedia"
        case .lexicon: return type == "Léxico"
        }
    }
}
struct KeyLinkScope: Codable, Hashable, Sendable {
    var kind: KeyLinkKind
    var language = ""
    /// Language belongs to the queried datatype, independently of UI language.
    var datatype: String { kind == .bible || kind == .commentary ? "bible" : language.isEmpty ? "text" : "text+" + language }
    func supports(_ resource: LibraryResource) -> Bool {
        guard kind.supports(resource) else { return false }
        guard !language.isEmpty else { return true }
        if kind == .dictionary || kind == .lexicon,
           let data = resource.libron?.originalInformation?.data(using: .utf8),
           let root = try? JSONDecoder().decode(XMLNode.self, from: data),
           let metadata = root.name == "metadata" ? root : root.child(named: "metadata"),
           let types = metadata.child(named: "data-types") {
            return types.children(named: "data-type").contains {
                $0.attributes["name"]?.lowercased() == datatype && $0.attributes["keylink"]?.lowercased() == "yes"
            }
        }
        return LibronMetadata.deriving(resource).languages.map(LibraryLanguages.canonical).contains(language)
    }
}
struct KeyLinkPreference: Codable, Equatable {
    var scope: KeyLinkScope
    var promoted: [LibraryCollectionMember] = []
    var disabled: [LibraryCollectionMember] = []
    var openCount = 1
}
struct ResourcePrioritiesSnapshot: Codable {
    var schemaVersion = 1
    var preferences: [KeyLinkPreference] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard preferences.count <= 128, Set(preferences.map(\.scope)).count == preferences.count else { throw Self.invalid() }
        for preference in preferences {
            let language = preference.scope.language
            guard language.utf8.count <= 32, language.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  language.isEmpty || LibraryLanguages.canonical(language) == language,
                  (1...8).contains(preference.openCount), preference.promoted.count <= 512, preference.disabled.count <= 8192 else { throw Self.invalid() }
            try LibraryCollectionsSnapshot(sets: [LibraryCollection(name: "KeyLink", members: preference.promoted),
                                                 LibraryCollection(name: "Disabled", members: preference.disabled)]).validate()
        }
    }
    private static func invalid() -> PersonalStateError { .invalid("Invalid resource priorities") }
}

/// Preferences never write to a source book, parallel group or collection.
@MainActor @Observable final class ResourcePriorities {
    private(set) var preferences: [KeyLinkPreference] = []
    private(set) var loadError: String?
    @ObservationIgnored private let file: PersonalStateFile<ResourcePrioritiesSnapshot>
    @ObservationIgnored private var canSave = false
    init(url: URL? = nil) {
        file = .init(url: url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/resource-priorities.json"))
        do { try reload() } catch { loadError = error.localizedDescription }
    }
    func reload() throws {
        canSave = false
        do {
            let snapshot = try file.load() ?? .init(); try snapshot.validate()
            preferences = snapshot.preferences; canSave = true; loadError = nil
        } catch { loadError = error.localizedDescription; throw error }
    }
    func preference(_ scope: KeyLinkScope) -> KeyLinkPreference {
        if let own = preferences.first(where: { $0.scope == scope }) { return own }
        var inherited = preferences.first { $0.scope == KeyLinkScope(kind: scope.kind) } ?? .init(scope: scope)
        inherited.scope = scope
        return inherited
    }
    func effectivePreference(_ scope: KeyLinkScope) -> KeyLinkPreference { preference(scope) }
    func reset(_ scope: KeyLinkScope) throws { try commit(preferences.filter { $0.scope != scope }) }
    func promote(_ resource: LibraryResource, in scope: KeyLinkScope) throws {
        guard scope.supports(resource) else { throw RebuildError.unsupportedFormat }
        try edit(scope) { value in
            if !value.promoted.contains(where: { $0.id == resource.id }) { value.promoted.append(.init(resource)) }
        }
    }
    func remove(_ id: String, in scope: KeyLinkScope) throws { try edit(scope) { $0.promoted.removeAll { $0.id == id } } }
    func move(_ id: String, in scope: KeyLinkScope, by delta: Int) throws {
        guard delta == 1 || delta == -1 else { return }
        try edit(scope) {
            guard let index = $0.promoted.firstIndex(where: { $0.id == id }), $0.promoted.indices.contains(index + delta) else { return }
            $0.promoted.swapAt(index, index + delta)
        }
    }
    func enabled(_ resource: LibraryResource, in scope: KeyLinkScope) -> Bool {
        !effectivePreference(scope).disabled.contains { $0.resolve(in: [resource]) != nil }
    }
    func setEnabled(_ enabled: Bool, resources: [LibraryResource], in scope: KeyLinkScope) throws {
        guard resources.allSatisfy(scope.supports) else { throw RebuildError.unsupportedFormat }
        try edit(scope) { value in
            let ids = Set(resources.map(\.id)); value.disabled.removeAll { ids.contains($0.id) }
            if !enabled { value.disabled += resources.map(LibraryCollectionMember.init) }
        }
    }
    func setOpenCount(_ count: Int, in scope: KeyLinkScope) throws { try edit(scope) { $0.openCount = count } }
    func rank(_ resource: LibraryResource, in scope: KeyLinkScope) -> Int? {
        effectivePreference(scope).promoted.firstIndex { $0.resolve(in: [resource]) != nil }
    }
    func ordered(_ resources: [LibraryResource], in scope: KeyLinkScope) -> [LibraryResource] {
        resources.filter { scope.supports($0) && enabled($0, in: scope) }.sorted {
            let a = rank($0, in: scope) ?? Int.max, b = rank($1, in: scope) ?? Int.max
            if a != b { return a < b }
            // Stable POSIX ordering is independent of UI locale and input order.
            let x = $0.title.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let y = $1.title.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return x == y ? $0.id < $1.id : x < y
        }
    }
    private func edit(_ scope: KeyLinkScope, _ action: (inout KeyLinkPreference) -> Void) throws {
        var next = preferences, value = preference(scope); action(&value)
        if let index = next.firstIndex(where: { $0.scope == scope }) { next[index] = value } else { next.append(value) }
        try commit(next)
    }
    private func commit(_ next: [KeyLinkPreference]) throws {
        guard canSave else { throw PersonalStateError.invalid(loadError ?? "Could not read resource priorities") }
        guard next != preferences else { return }
        let snapshot = ResourcePrioritiesSnapshot(preferences: next); try snapshot.validate(); try file.save(snapshot)
        preferences = next; loadError = nil
    }
}
