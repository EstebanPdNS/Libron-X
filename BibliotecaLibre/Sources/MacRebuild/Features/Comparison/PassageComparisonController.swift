import Foundation
import Observation
import LibronixCore

struct PassageComparisonRow: Identifiable, Sendable {
    let reference: String
    let cells: [Cell]
    var id: String { reference }
    struct Cell: Identifiable, Sendable {
        let resourceID: String
        let verse: BiblePassageVerse?
        let differences: [TextDifference]
        let comparisonError: String?
        var id: String { resourceID }
    }
}

private actor PassageComparisonFormatting {
    func rows(_ editions: [BiblePassageEdition], requested: String, baseID: String,
              options: TextComparisonOptions) throws -> [PassageComparisonRow] {
        let indexes = editions.map { Dictionary(uniqueKeysWithValues: $0.verses.map { ($0.key, $0) }) }
        let baseIndex = editions.firstIndex { $0.resource.id == baseID }
        return try BiblePassageReport.references(in: editions, requested: requested).map { reference in
            try Task.checkCancellation()
            let base = baseIndex.flatMap { indexes[$0][reference] }
            let cells = try editions.enumerated().map { index, edition -> PassageComparisonRow.Cell in
                let verse = indexes[index][reference]
                var differences: [TextDifference] = [], error: String?
                if edition.resource.id != baseID, let verse, let base {
                    do { differences = try TextComparison.differences(base: base.text, compared: verse.text, options: options) }
                    catch is CancellationError { throw CancellationError() }
                    catch let problem { error = problem.localizedDescription }
                }
                return .init(resourceID: edition.resource.id, verse: verse, differences: differences, comparisonError: error)
            }
            return .init(reference: reference, cells: cells)
        }
    }
}

@MainActor @Observable final class PassageComparisonController {
    var reference = ""
    var selectedIDs: Set<String> = []
    var baseID = ""
    var options = TextComparisonOptions()
    private(set) var editions: [BiblePassageEdition] = []
    private(set) var rows: [PassageComparisonRow] = []
    private(set) var submittedReference = ""
    private(set) var isLoading = false
    private(set) var progress = ""
    private(set) var error: String?
    private(set) var completed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let service: BiblePassageReportService
    @ObservationIgnored private let formatting = PassageComparisonFormatting()
    init(provider: any LibrarySearchContentProvider = WorkspaceSearchReader()) {
        service = .init(provider: provider)
    }
    func cancel() { generation += 1; task?.cancel(); task = nil; isLoading = false }
    func invalidate() { cancel(); editions = []; rows = []; completed = false; error = nil }
    func setSensitivity(_ field: WritableKeyPath<TextComparisonOptions, Bool>, to value: Bool) {
        guard options[keyPath: field] != value else { return }
        options[keyPath: field] = value
        compareAgain()
    }
    func setBase(_ value: String) {
        guard baseID != value else { return }
        baseID = value; compareAgain()
    }
    func run(resources: [LibraryResource]) {
        invalidate()
        let requested = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = resources.filter { selectedIDs.contains($0.id) && KeyLinkKind.bible.supports($0) }
        guard !selected.isEmpty, selected.count <= 16, selected.contains(where: { $0.id == baseID }) else {
            error = L("Selecciona entre una y dieciséis Biblias y una versión base."); return
        }
        let range: BibleSearchRange
        do { range = try .parse(requested) }
        catch { self.error = L(error.localizedDescription); return }
        let token = generation, options = options, base = baseID, service = service, formatting = formatting
        submittedReference = requested; isLoading = true
        task = Task { [weak self] in
            do {
                var reports: [BiblePassageEdition] = []
                for resource in selected {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.progress = resource.title
                    reports.append(try await service.read(resource, range: range))
                }
                let rows = try await formatting.rows(reports, requested: requested, baseID: base, options: options)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.editions = reports; self.rows = rows; self.completed = true; self.isLoading = false; self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false; self.task = nil
                if !(error is CancellationError) { self.error = L(error.localizedDescription) }
            }
        }
    }
    func compareAgain() {
        guard !editions.isEmpty else { return }
        cancel(); rows = []; completed = false; isLoading = true
        let token = generation, editions = editions, requested = submittedReference, base = baseID, options = options, formatting = formatting
        task = Task { [weak self] in
            do {
                let rows = try await formatting.rows(editions, requested: requested, baseID: base, options: options)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.rows = rows; self.completed = true; self.isLoading = false; self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false; self.task = nil
                if !(error is CancellationError) { self.error = L(error.localizedDescription) }
            }
        }
    }
    func verifySources() throws { for edition in editions { try LibrarySearchFileStamp.verify(edition.sourceStamps) } }
    @discardableResult func open(_ verse: BiblePassageVerse, edition: BiblePassageEdition, in workspace: StudyWorkspace) throws -> ReaderSession {
        guard workspace.availableResources.contains(edition.resource), edition.verses.contains(verse) else {
            throw PersonalStateError.invalid(L("Recurso no disponible"))
        }
        try LibrarySearchFileStamp.verify(edition.sourceStamps)
        let reader = workspace.open(edition.resource, startReading: false)
        reader.load(.init(ordinal: verse.sectionOrdinal), selection: verse.sourceRange.nsRange,
                    expectedFingerprint: verse.sourceFingerprint, expectedSourceStamps: edition.sourceStamps)
        return reader
    }
    func exportCSV() throws -> String {
        guard completed else { throw PersonalStateError.invalid(L("El informe todavía no está completo.")) }
        try verifySources()
        return BiblePassageReport.csv(editions: editions, requested: submittedReference)
    }
    func writeCSV(to url: URL) throws {
        let destination = url.resolvingSymlinksInPath().standardizedFileURL
        guard !editions.flatMap(\.sourceStamps).contains(where: {
            $0.url.resolvingSymlinksInPath().standardizedFileURL == destination
        }) else {
            throw PersonalStateError.invalid(L("Elige otro destino. La exportación no puede sustituir un recurso de la biblioteca."))
        }
        let data = Data(try exportCSV().utf8)
        try verifySources(); try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
    deinit { task?.cancel() }
}
