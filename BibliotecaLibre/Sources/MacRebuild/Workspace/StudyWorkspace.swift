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
    /// Concentrated reading changes presentation only; existing pane geometry
    /// and the archived workspace remain untouched.
    private(set) var focusedReaderID: UUID?
    var focusedReader: ReaderSession? { readers.first { $0.id == focusedReaderID } }
    func enterFocusedReading() {
        guard let reader = activeReader, !reader.isMinimized, !showsHome else { return }
        focusedReaderID = reader.id
    }
    func exitFocusedReading() { focusedReaderID = nil }
    var libraryQuery = ""
    var librarySelection: String?
    var keepLibraryOpen = false
    var librarySortByAuthor = false
    var librarySortField = LibraryField.title
    var librarySortOrder = SortOrder.forward
    var libraryGroup = "all"
    var libraryFacet = LibraryField.category
    var libraryFacetValue = ""
    var isImporting = false
    var importProgress = ""
    var error: String?
    var libraryRoot: URL?
    var referenceTargetID: UUID?
    var pendingLibraryReference: String?
    var pendingNoteID: UUID?
    var personalSearchDestination: BibleReferencePersonalDestination?
    var personalNavigationID = UUID()
    var activeTool: WorkspaceTool?
    var annotationNavigationCursor: ReaderAnnotationCursor?
    @ObservationIgnored var researchDraftSaver: (() -> Bool)?
    func saveResearchDraftIfNeeded() -> Bool { researchDraftSaver?() ?? true }
    func closeActiveTool() {
        guard activeTool != .researchInbox || saveResearchDraftIfNeeded() else { return }
        activeTool = nil
    }
    var showsHome = false { didSet { if showsHome { exitFocusedReading() } } }
    var snapPreview: PaneFrame?
    var dictionary = DictionaryController()
    var search = WorkspaceSearchController()
    var referenceSearch = WorkspaceReferenceSearchController()
    var annotationSearch = PersonalAnnotationSearchController()
    var personal: WorkspacePersonalState
    var resourceVisibility: LibraryResourceVisibility
    var availableBibleVersions: [LibraryResource] = []
    var resourcePriorities: ResourcePriorities
    var keyLinks = KeyLinkController()
    var passageComparison = PassageComparisonController()
    var passageGuide = PassageGuideController()
    var associationNavigation = AssociationNavigationController()
    var bibliography = BibliographyController()
    var editions = LibraryEditionsController()
    var collections: LibraryCollections
    var resourceAssociations: ResourceAssociationSets
    var parallelBibleSets: ParallelBibleSets
    var recentWorkspaces: RecentWorkspaces
    @ObservationIgnored var bibleVersionTask: Task<Void, Never>?
    @ObservationIgnored var originalFavoriteTask: Task<Void, Never>?
    @ObservationIgnored var originalFavoriteGeneration = 0
    @ObservationIgnored let bibleVersionCatalog = BibleVersionCatalog()
    @ObservationIgnored private let importer = LibraryImporter()
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importGeneration = 0
    @ObservationIgnored private var accessURLs: [URL] = []
    init(personal: WorkspacePersonalState? = nil, resourceVisibility: LibraryResourceVisibility? = nil, recentWorkspaces: RecentWorkspaces? = nil, parallelBibleSets: ParallelBibleSets? = nil, collections: LibraryCollections? = nil, resourcePriorities: ResourcePriorities? = nil, resourceAssociations: ResourceAssociationSets? = nil) {
        self.personal = personal ?? WorkspacePersonalState()
        self.resourceVisibility = resourceVisibility ?? LibraryResourceVisibility()
        self.resourcePriorities = resourcePriorities ?? ResourcePriorities()
        self.collections = collections ?? LibraryCollections()
        self.parallelBibleSets = parallelBibleSets ?? ParallelBibleSets()
        self.resourceAssociations = resourceAssociations ?? ResourceAssociationSets()
        self.recentWorkspaces = recentWorkspaces ?? RecentWorkspaces()
        self.search.history = self.personal.searchHistory
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
        availableResources.filter { resource in
            let m = LibronMetadata.deriving(resource)
            let queryMatches = libraryQuery.isEmpty || (m.searchText + " " + resource.fileName + " " + resource.location.lastPathComponent + " " + (resource.legacyIdentifier ?? "") + " " + LibraryLanguages.searchNames(m.languages)).localizedStandardContains(libraryQuery)
            let groupMatches: Bool
            if libraryGroup == "dictionaries" { groupMatches = LibronDictionaryIndex.supports(resource) }
            else if libraryGroup.hasPrefix("language:") { groupMatches = m.languages.map(LibraryLanguages.canonical).contains(String(libraryGroup.dropFirst(9))) }
            else if libraryGroup.hasPrefix("personal:"), let uuid = UUID(uuidString: String(libraryGroup.dropFirst(9))) {
                groupMatches = parallelBibleSets.sets.first { $0.id == uuid }?.members.contains { $0.resolve(in: [resource]) != nil } == true
            } else if libraryGroup.hasPrefix("collection:") {
                let id = UUID(uuidString: String(libraryGroup.dropFirst(11)))
                groupMatches = collections.sets.first { $0.id == id }?.contains(resource) == true
            } else { groupMatches = true }
            return queryMatches && groupMatches && (libraryFacetValue.isEmpty || libraryFacet.value(resource) == libraryFacetValue)
        }.sortedForLibrary(using: [LibraryResourceSort(librarySortByAuthor ? .author : librarySortField, order: librarySortOrder)])
    }

    var bibleGroups: [ParallelBibleSet] {
        let bibles = availableResources.filter { LibronMetadata.deriving($0).resourceType == "Biblia" }
        let languages = Set(bibles.flatMap { LibronMetadata.deriving($0).languages }.map(LibraryLanguages.canonical)).sorted()
        let automatic = languages.filter { !parallelBibleSets.excludedAutomaticLanguages.contains($0) }.map { code -> ParallelBibleSet in
            let hash = LibrarySearchService.textFingerprint("libron-language-group:" + code)
            let h = Array(hash.prefix(32))
            let groups = [String(h[0..<8]), String(h[8..<12]), String(h[12..<16]),
                          String(h[16..<20]), String(h[20..<32])]
            let uuid = UUID(uuidString: groups.joined(separator: "-"))!
            return ParallelBibleSet(id: uuid, name: LibraryLanguages.name(code), members: bibles.filter {
                LibronMetadata.deriving($0).languages.map(LibraryLanguages.canonical).contains(code)
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(ParallelBibleMember.init), automaticLanguage: code)
        }
        return automatic + parallelBibleSets.sets
    }
    var libraryLanguages: [String] {
        Set(availableResources.flatMap { LibronMetadata.deriving($0).languages }.map(LibraryLanguages.canonical)).sorted { LibraryLanguages.name($0).localizedStandardCompare(LibraryLanguages.name($1)) == .orderedAscending }
    }

    /// Resolve real imported locations, including selected hidden resources in Settings.
    func resourceDirectory(for resourceID: String?) -> URL? {
        let location = resources.first { $0.id == resourceID }.map { $0.packageLocation ?? $0.location }
            ?? resourceVisibility.hidden.first { $0.id == resourceID }.map { URL(fileURLWithPath: $0.id) }
        guard let directory = location?.deletingLastPathComponent() ?? libraryRoot,
              directory.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory.standardizedFileURL
    }
    var currentResourceDirectory: URL? {
        resourceDirectory(for: filteredResources.first { $0.id == librarySelection }?.id)
    }
    func openResourceDirectory(for resourceID: String?, using opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        guard let directory = resourceDirectory(for: resourceID) else { return }
        if !opener(directory) { error = L("No se pudo abrir el directorio en Finder.") }
    }
    func openCurrentResourceDirectory(using opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        openResourceDirectory(for: filteredResources.first { $0.id == librarySelection }?.id, using: opener)
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
        search.clear()
        keyLinks.clear()
        passageComparison.invalidate()
        passageGuide.clear()
        associationNavigation.cancel()
        referenceSearch.clear()
        if !availableResources.contains(where: { $0.id == search.resourceID }) { search.resourceID = nil }
        if !availableResources.contains(where: { $0.id == librarySelection }) { librarySelection = nil }
    }
    func activate(_ reader: ReaderSession) {
        // Wheel events can arrive at the display refresh rate. An already
        // frontmost reader must not invalidate/reorder the whole workspace.
        if activeID == reader.id, readers.last === reader, !reader.isMinimized, !showsHome { return }
        cancelOriginalFavoriteNavigation()
        guard readers.contains(where: { $0 === reader }) else { return }
        if focusedReaderID != nil && focusedReaderID != reader.id { exitFocusedReading() }
        reader.isMinimized = false; activeID = reader.id
        if reader.canSynchronizeBible {
            for follower in readers where follower.commentaryFollowsActiveBible { follower.commentarySourceID = reader.id }
            if let reference = reader.currentReference { updateCommentaryFollowers(from: reader, reference: reference) }
        }
        showsHome = false
        readers.removeAll { $0 === reader }; readers.append(reader)
    }
    @discardableResult func open(_ resource: LibraryResource, startReading: Bool = true, destination: ReaderDestination? = nil, loader: ReaderSession.Loader? = nil) -> ReaderSession {
        cancelOriginalFavoriteNavigation()
        exitFocusedReading()
        let reader = ReaderSession(resource: resource, loader: loader ?? ReaderSession.read)
        showsHome = false
        connect(reader)
        let offset = Double(readers.count % 6) * 0.035
        reader.frame.x += offset; reader.frame.y += offset
        reader.frame = reader.frame.constrained()
        readers.append(reader); readerOrder.append(reader.id); activeID = reader.id
        if LibronMetadata.deriving(resource).resourceType == "Comentario bíblico" {
            reader.commentaryResourceID = resource.id; reader.commentaryFollowsActiveBible = true
            if startReading { openCommentary(resource, replacing: reader) }
        } else if startReading {
            if reader.canSynchronizeBible {
                for follower in readers where follower.commentaryFollowsActiveBible { follower.commentarySourceID = reader.id }
            }
            reader.load(destination ?? .init(ordinal: 0, prefersContentsStart: true))
        }
        return reader
    }
    func close(_ reader: ReaderSession) {
        cancelOriginalFavoriteNavigation()
        if focusedReaderID == reader.id { exitFocusedReading() }
        let order = orderedReaders
        let successor = order.firstIndex(where: { $0 === reader }).flatMap { index in
            order.dropFirst(index + 1).first ?? order.prefix(index).first
        }
        reader.cancel(); readers.removeAll { $0 === reader }
        for follower in readers where follower.commentarySourceID == reader.id {
            let replacement = follower.commentaryFollowsActiveBible ? bibleReaders.last : nil
            follower.commentarySourceID = replacement?.id
            if let replacement, let reference = replacement.currentReference {
                updateCommentaryFollowers(from: replacement, reference: reference)
            }
        }
        readerOrder.removeAll { $0 == reader.id }
        if activeID == reader.id {
            activeID = nil
            if let successor { activate(successor) }
        }
        if referenceTargetID == reader.id { referenceTargetID = nil }
    }
    func closeAll() { exitFocusedReading(); cancelOriginalFavoriteNavigation(); for reader in readers { reader.cancel() }; readers = []; readerOrder = []; activeID = nil; referenceTargetID = nil }
    func minimize(_ reader: ReaderSession) {
        cancelOriginalFavoriteNavigation()
        if focusedReaderID == reader.id { exitFocusedReading() }
        reader.isMinimized = true
        if activeID == reader.id { activeID = visibleReaders.last?.id }
    }
    func arrange(_ arrangement: PaneArrangement) {
        let panes = visibleReaders
        guard !panes.isEmpty else { return }
        PaneLayoutMotion.perform {
            for (index, reader) in panes.enumerated() {
                reader.isMaximized = false; reader.unsnappedFrame = nil
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
    }
    func chooseLibrary() { chooseResources(foldersOnly: true) }
    func chooseResources(foldersOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = L("Importar recursos")
        panel.canChooseDirectories = true; panel.canChooseFiles = !foldersOnly; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.confirmResourceConversion(panel.urls)
        }
    }
    func confirmResourceConversion(_ urls: [URL]) {
        let preferences = LibraryPreferences.shared
        var backup = preferences.backupOriginals
        if preferences.askBeforeConversion {
            let alert = NSAlert(); alert.messageText = L("Convertir a .libron")
            alert.informativeText = L("Los archivos se convertirán a .libron. ¿Deseas guardar una copia del original en la carpeta backup de la biblioteca?")
            alert.addButton(withTitle: L("Sí")); alert.addButton(withTitle: L("No")); alert.addButton(withTitle: L("Cancelar"))
            alert.showsSuppressionButton = true; alert.suppressionButton?.title = L("No volver a preguntar")
            let answer = alert.runModal()
            guard answer != .alertThirdButtonReturn else { return }
            backup = answer == .alertFirstButtonReturn
            preferences.backupOriginals = backup
            preferences.askBeforeConversion = alert.suppressionButton?.state != .on
        }
        convertResources(urls, backup: backup)
    }
    func convertResources(_ urls: [URL], backup: Bool) {
        importTask?.cancel(); importGeneration += 1
        let token = importGeneration, destination = LibraryPreferences.shared.directory
        for url in urls where url.startAccessingSecurityScopedResource() { accessURLs.append(url) }
        isImporting = true; error = nil
        importTask = Task { [weak self] in
            do {
                let resources = try await LibronLibrary().convert(urls, to: destination, backup: backup) { [weak self] in await self?.updateProgress($0, token: token) }
                var pending: [String] = []
                for resource in resources {
                    try Task.checkCancellation()
                    do { _ = try await LibronNativeNormalizer.shared.convert(resource) }
                    catch is CancellationError { throw CancellationError() }
                    catch { pending.append(resource.title+": "+error.localizedDescription) }
                }

                guard let self, self.importGeneration == token, !Task.isCancelled else { return }
                self.resources = resources; self.includeBundledDictionaries(); self.libraryRoot = destination; self.isImporting = false
                if !pending.isEmpty { self.error = pending.joined(separator:"\n") }
            } catch {
                guard let self, self.importGeneration == token else { return }
                self.error = error.localizedDescription; self.isImporting = false
            }
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
                self.resources = result.resources; self.includeBundledDictionaries(); self.isImporting = false
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
        cancelOriginalFavoriteNavigation()
        bibleVersionTask?.cancel()
        search.cancel()
        keyLinks.cancel()
        passageComparison.cancel()
        passageGuide.clear()
        associationNavigation.cancel()
        bibliography.cancel()
        referenceSearch.cancel()
        do { try personal.save() } catch { self.error = error.localizedDescription }
        closeAll(); importGeneration += 1; importTask?.cancel(); isImporting = false
        for url in accessURLs { url.stopAccessingSecurityScopedResource() }
        accessURLs = []
    }
}
