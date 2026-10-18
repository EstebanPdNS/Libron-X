import Foundation
import Observation
import LibronixCore

struct KeyLinkMatch: Identifiable, Sendable {
    let resource: LibraryResource
    let destination: ReaderDestination
    let label: String
    let page: ReaderPage
    let stamps: [LibrarySearchFileStamp]
    var id: String { resource.id }
    var excerpt: String {
        let text = page.text as NSString
        let start = min(max(0, page.selection?.location ?? 0), text.length)
        return String(text.substring(from: start).prefix(320))
    }
}
@MainActor @Observable final class KeyLinkController {
    typealias Lookup = @Sendable (LibraryResource, KeyLinkScope, String) async throws -> KeyLinkMatch?
    var scope = KeyLinkScope(kind: .dictionary)
    var query = ""
    private(set) var results: [KeyLinkMatch] = []
    private(set) var failures: [String] = []
    private(set) var examined = 0
    private(set) var isLoading = false
    private(set) var completed = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let lookup: Lookup
    init(lookup: @escaping Lookup = KeyLinkController.resolve) { self.lookup = lookup }
    func cancel() { generation += 1; task?.cancel(); task = nil; isLoading = false; completed = false }
    func clear() { cancel(); results = []; failures = []; examined = 0 }
    func run(workspace: StudyWorkspace, openPreferred: Bool = false) {
        clear()
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf16.count <= 512, !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return }
        let scope = scope, token = generation
        if scope.kind == .bible || scope.kind == .commentary {
            do { _ = try BibleCopyPassage.parse(input) } catch { failures = [error.localizedDescription]; completed = true; return }
        }
        let resources = workspace.resourcePriorities.ordered(workspace.availableResources, in: scope)
        let count = workspace.resourcePriorities.effectivePreference(scope).openCount
        isLoading = true
        task = Task { [weak self, weak workspace, lookup] in
            guard let self, let workspace else { return }
            for resource in resources {
                do {
                    try Task.checkCancellation()
                    let match = try await lookup(resource, scope, input)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.examined += 1
                    if let match {
                        guard match.resource == resource, workspace.availableResources.contains(resource) else { continue }
                        self.results.append(match)
                        if openPreferred && self.results.count >= count { break }
                    }
                } catch is CancellationError {
                    if self.generation == token { self.isLoading = false; self.task = nil }
                    return
                }
                catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.examined += 1; self.failures.append(resource.title + ": " + error.localizedDescription)
                }
            }
            guard self.generation == token, !Task.isCancelled else { return }
            self.isLoading = false; self.completed = true; self.task = nil
            if openPreferred { for result in self.results.prefix(count) { workspace.openKeyLink(result) } }
        }
    }
    nonisolated static func resolve(_ resource: LibraryResource, scope: KeyLinkScope, query: String) async throws -> KeyLinkMatch? {
        try Task.checkCancellation()
        guard scope.supports(resource) else { return nil }
        var urls = [resource.location]
        if let index = resource.indexLocation { urls.append(index) }
        if let package = resource.packageLocation { urls.append(package.appendingPathComponent("manifest.json")) }
        if let native = LibronNativeReader.location(resource) { urls.append(native) }
        let stamps = try urls.map(LibrarySearchFileStamp.capture)
        let destination: ReaderDestination, label: String
        switch scope.kind {
        case .bible, .commentary:
            let passage = try BibleCopyPassage.parse(query)
            let first = "\(passage.start.sourceBook) \(passage.start.chapter):\(passage.start.verse)"
            let last = "\(passage.end.sourceBook) \(passage.end.chapter):\(passage.end.verse)"
            let end = passage.start == passage.end ? nil : last
            if resource.format == .eSwordSQLite {
                guard let ordinal = try ESwordResource.referenceOrdinal(resource.location, reference:first, endReference:end) else {
                    try LibrarySearchFileStamp.verify(stamps); return nil
                }
                // Commentary rows retain their own physical article identity;
                // they are not relabelled as Bible text or given invented anchors.
                destination = scope.kind == .commentary ? .init(ordinal:ordinal) : .init(ordinal:ordinal,reference:first,endReference:end)
            } else { destination = .init(ordinal:0,reference:first,endReference:end) }
            label = query
        case .dictionary, .lexicon:
            guard let entry = try await LibronDictionaryIndexService.shared.match(query, in: resource) else {
                try LibrarySearchFileStamp.verify(stamps); return nil
            }
            destination = .init(ordinal: entry.ordinal); label = entry.headword
        }
        let page: ReaderPage
        do {
            if LibronNativeReader.location(resource) != nil { page = try await LibronNativeReader().read(resource, destination) }
            else { page = try await ReaderSession.readOriginal(resource, destination) }
        } catch RebuildError.referenceNotFound { try LibrarySearchFileStamp.verify(stamps); return nil }
        try Task.checkCancellation(); try LibrarySearchFileStamp.verify(stamps)
        var resolved = destination; resolved.ordinal = page.destination.ordinal
        return .init(resource: resource, destination: resolved, label: label, page: page, stamps: stamps)
    }
    deinit { task?.cancel() }
}
@MainActor extension StudyWorkspace {
    func openKeyLink(_ result: KeyLinkMatch) {
        guard availableResources.contains(result.resource) else { error = L("Recurso no disponible"); return }
        do { try LibrarySearchFileStamp.verify(result.stamps) }
        catch { self.error = error.localizedDescription; return }
        let native = LibronNativeReader()
        let reader = open(result.resource, startReading: false, loader: { resource, destination in
            if LibronNativeReader.location(resource) != nil { return try await native.read(resource, destination) }
            return try await ReaderSession.readOriginal(resource, destination)
        })
        reader.load(result.destination, expectedFingerprint: result.page.oeb == nil ? LibrarySearchService.textFingerprint(result.page.text) : nil,
                    expectedSourceStamps: result.stamps)
    }
}
