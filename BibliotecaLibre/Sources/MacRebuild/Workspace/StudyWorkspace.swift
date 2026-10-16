import AppKit
import LibronixCore
import Observation

/// Relative coordinates survive workspace resizing without converting panels into OS windows.
struct PaneFrame: Equatable, Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    func constrained() -> Self {
        let w = min(1, max(0.2, width)), h = min(1, max(0.2, height))
        return Self(x: min(max(0, x), 1 - w), y: min(max(0, y), 1 - h), width: w, height: h)
    }
}
enum PaneArrangement { case cascade, horizontal, vertical }

@MainActor @Observable final class StudyWorkspace {
    var resources: [LibraryResource] = []
    var readers: [ReaderSession] = []
    var readerOrder: [UUID] = []
    var activeID: UUID?
    var libraryQuery = ""
    var librarySelection: String?
    var keepLibraryOpen = false
    var librarySortByAuthor = false
    var isImporting = false
    var importProgress = ""
    var error: String?
    var libraryRoot: URL?
    var referenceTargetID: UUID?
    var pendingLibraryReference: String?
    var activeTool: WorkspaceTool?
    var showsHome = false
    var search = WorkspaceSearchController()
    var personal: WorkspacePersonalState
    var resourceVisibility: LibraryResourceVisibility
    var availableBibleVersions: [LibraryResource] = []
    var parallelBibleSets: ParallelBibleSets
    var recentWorkspaces: RecentWorkspaces
    @ObservationIgnored var bibleVersionTask: Task<Void, Never>?
    @ObservationIgnored let bibleVersionCatalog = BibleVersionCatalog()
    @ObservationIgnored private let importer = LibraryImporter()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importGeneration = 0
    @ObservationIgnored private var accessURLs: [URL] = []
    init(personal: WorkspacePersonalState? = nil, resourceVisibility: LibraryResourceVisibility? = nil, recentWorkspaces: RecentWorkspaces? = nil, parallelBibleSets: ParallelBibleSets? = nil) {
        self.personal = personal ?? WorkspacePersonalState()
        self.resourceVisibility = resourceVisibility ?? LibraryResourceVisibility()
        self.parallelBibleSets = parallelBibleSets ?? ParallelBibleSets()
        self.recentWorkspaces = recentWorkspaces ?? RecentWorkspaces()
    }
    var availableResources: [LibraryResource] { resources.filter { !resourceVisibility.isHidden($0) } }
    var activeReader: ReaderSession? { readers.first { $0.id == activeID } }
    var visibleReaders: [ReaderSession] { readers.filter { !$0.isMinimized } }
    /// Window commands follow opening order, independently of the front-to-back stack.
    var orderedReaders: [ReaderSession] {
        let byID = Dictionary(uniqueKeysWithValues: readers.map { ($0.id, $0) })
        let known = Set(readerOrder)
        return readerOrder.compactMap { byID[$0] } + readers.filter { !known.contains($0.id) }
    }
    /// Keep native view siblings in creation order. Focus changes only their
    /// z-level, so an AppKit menu or glass group is not moved in the view tree.
    var presentedReaders: [ReaderSession] {
        let visible = visibleReaders, known = Set(readerOrder)
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        return readerOrder.compactMap { byID[$0] } + visible.filter { !known.contains($0.id) }
    }
    func stackingLevel(of reader: ReaderSession) -> Double {
        Double(readers.firstIndex { $0 === reader } ?? 0)
    }
    var filteredResources: [LibraryResource] {
        availableResources.filter { libraryQuery.isEmpty || ($0.title + " " + ($0.author ?? "") + " " + $0.fileName).localizedStandardContains(libraryQuery) }
            .sorted { lhs, rhs in
                let a = librarySortByAuthor ? lhs.author ?? "" : lhs.title
                let b = librarySortByAuthor ? rhs.author ?? "" : rhs.title
                let order = a.localizedStandardCompare(b)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }
    func hideLibraryResources(_ ids: Set<String>) throws {
        let selected = resources.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { throw PersonalStateError.invalid("Algún recurso seleccionado ya no está en la biblioteca.") }
        try resourceVisibility.hide(selected); libraryVisibilityChanged()
    }
    func restoreLibraryResources(_ ids: Set<String>) throws {
        try resourceVisibility.restore(ids); libraryVisibilityChanged()
    }
    private func libraryVisibilityChanged() {
        // Invalidate results from the old scope before accepting another search.
        search.cancel(); search.report = nil; search.progress = nil; search.error = nil
        if !availableResources.contains(where: { $0.id == search.resourceID }) { search.resourceID = nil }
        if !availableResources.contains(where: { $0.id == librarySelection }) { librarySelection = nil }
    }
    func activate(_ reader: ReaderSession) {
        // Wheel events can arrive at the display refresh rate. An already
        // frontmost reader must not invalidate/reorder the whole workspace.
        if activeID == reader.id, readers.last === reader, !reader.isMinimized, !showsHome { return }
        guard readers.contains(where: { $0 === reader }) else { return }
        reader.isMinimized = false; activeID = reader.id
        showsHome = false
        readers.removeAll { $0 === reader }; readers.append(reader)
    }
    @discardableResult func open(_ resource: LibraryResource, startReading: Bool = true, destination: ReaderDestination? = nil) -> ReaderSession {
        let reader = ReaderSession(resource: resource)
        showsHome = false
        connect(reader)
        let offset = Double(readers.count % 6) * 0.035
        reader.frame.x += offset; reader.frame.y += offset
        reader.frame = reader.frame.constrained()
        readers.append(reader); readerOrder.append(reader.id); activeID = reader.id
        if startReading { reader.load(destination ?? .init(ordinal: 0, prefersContentsStart: true)) }
        return reader
    }
    func close(_ reader: ReaderSession) {
        reader.cancel(); readers.removeAll { $0 === reader }
        readerOrder.removeAll { $0 == reader.id }
        if activeID == reader.id { activeID = visibleReaders.last?.id }
        if referenceTargetID == reader.id { referenceTargetID = nil }
    }
    func closeAll() { for reader in readers { reader.cancel() }; readers = []; readerOrder = []; activeID = nil; referenceTargetID = nil }
    func minimize(_ reader: ReaderSession) {
        reader.isMinimized = true
        if activeID == reader.id { activeID = visibleReaders.last?.id }
    }
    func arrange(_ arrangement: PaneArrangement) {
        let panes = visibleReaders
        guard !panes.isEmpty else { return }
        for (index, reader) in panes.enumerated() {
            reader.isMaximized = false
            let n = Double(panes.count), i = Double(index)
            switch arrangement {
            case .vertical: reader.frame = .init(x: i / n, y: 0, width: 1 / n, height: 1)
            case .horizontal: reader.frame = .init(x: 0, y: i / n, width: 1, height: 1 / n)
            case .cascade:
                let offset = Double(index % 6) * 0.035
                reader.frame = .init(x: offset, y: offset, width: 0.80, height: 0.80)
            }
        }
    }
    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = L("Abrir carpeta de recursos…"); panel.canChooseDirectories = true
        panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.importLibrary(url) }
        }
    }
    func importLibrary(_ url: URL) {
        importTask?.cancel(); importGeneration += 1
        let token = importGeneration
        if url.startAccessingSecurityScopedResource() { accessURLs.append(url) }
        isImporting = true; error = nil
        importTask = Task { [weak self, importer] in
            do {
                let result = try await importer.importDirectory(at: url) { [weak self] progress in
                    await self?.updateProgress(progress, token: token)
                }
                guard let self, token == self.importGeneration, !Task.isCancelled else { return }
                self.resources = result.resources; self.isImporting = false
                self.libraryRoot = url
            } catch {
                guard let self, token == self.importGeneration, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isImporting = false
            }
        }
    }
    func cancelImport() { importGeneration += 1; importTask?.cancel(); importTask = nil; isImporting = false }
    private func updateProgress(_ value: ImportProgress, token: Int) {
        guard token == importGeneration else { return }
        importProgress = "\(value.completed) / \(value.total)"
    }
    func shutdown() {
        bibleVersionTask?.cancel()
        search.cancel()
        do { try personal.save() } catch { self.error = error.localizedDescription }
        closeAll(); importGeneration += 1; importTask?.cancel(); isImporting = false
        for url in accessURLs { url.stopAccessingSecurityScopedResource() }
        accessURLs = []
    }
}
