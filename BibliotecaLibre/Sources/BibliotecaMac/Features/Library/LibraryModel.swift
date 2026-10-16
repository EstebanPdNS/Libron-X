import AppKit
import Foundation
import LibronixCore
import Observation

enum LibrarySection: String, CaseIterable, Identifiable {
    case all, recovered, help, collections, search, favorites, documents
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "Todos los recursos"
        case .recovered: "Títulos recuperados"
        case .help: "Ayudas y manuales"
        case .collections: "Colecciones y estilos"
        case .search: "Buscar en libros"
        case .favorites: "Favoritos y marcadores"
        case .documents: "Documentos de estudio"
        }
    }
    var symbol: String {
        switch self {
        case .all: "books.vertical"
        case .recovered: "text.book.closed"
        case .help: "questionmark.circle"
        case .collections: "square.grid.2x2"
        case .search: "text.magnifyingglass"
        case .favorites: "star"
        case .documents: "note.text"
        }
    }
}

enum CatalogSort: String, CaseIterable, Identifiable {
    case title, author, format
    var id: Self { self }
    var title: String { switch self { case .title: "Título"; case .author: "Autor"; case .format: "Formato" } }
}

/// Each window owns its selection, filters, focus and asynchronous reader.
@MainActor @Observable final class LibraryModel {
    let id = UUID()
    let creationDate = Date()
    let store: LibraryStore
    let reader = ResourceReaderModel()
    let bookSearch = LibrarySearchModel()
    let output: ReaderOutputModel
    let bibleCopy: BibleCopyModel
    var selection: String? { didSet { if selection != oldValue { cancelOriginalNavigation(); output.cancelPreparation() } } }
    var section: LibrarySection = .all { didSet { if section != oldValue { cancelOriginalNavigation(); output.cancelPreparation() } } }
    var searchText = ""
    var format: ResourceFormat?
    var sort: CatalogSort = .title
    var searchFocusRequest = 0
    var linkGroup = ReaderLinkGroup.none { didSet { if !restoring { store.join(self, group: linkGroup) } } }
    var destinationError: String?
    var selectedDocumentID: UUID? { didSet { if selectedDocumentID != oldValue { cancelOriginalNavigation() } } }
    var selectedNoteID: UUID? { didSet { if selectedNoteID != oldValue { cancelOriginalNavigation() } } }
    var isResolvingOriginalDestination = false
    @ObservationIgnored private let originalLocatorService = LegacyContentService()
    @ObservationIgnored private var originalLocatorTask: Task<Void, Never>?
    @ObservationIgnored private var originalLocatorGeneration = 0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var pendingRestore: WorkspaceWindowState?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var restoredFrame: [Double]?
    init(store: LibraryStore) {
        self.store = store; output = ReaderOutputModel(settings:store.printSettings)
        bibleCopy = BibleCopyModel(settings:store.bibleCopySettings);store.register(self)
        reader.didNavigate = { [weak self] location, notify in
            guard let self else { return }; self.output.cancelPreparation()
            if notify { self.store.synchronize(location, from: self) }
        }
    }
    var snapshot: LibrarySnapshot? { store.snapshot }
    var metadata: MetadataSnapshot? { store.metadata }
    var isImporting: Bool { store.isImporting }
    var progress: ImportProgress? { store.progress }
    var errorMessage: String? { get { store.errorMessage } set { store.errorMessage = newValue } }
    var resources: [LibraryResource] { snapshot?.resources ?? [] }
    var visibleResources: [LibraryResource] {
        let filtered = CatalogQuery(text: searchText, format: format,
            metadataOnly: section == .recovered).apply(to: resources)
        let shown = section == .help ? filtered.filter(\.isHelp) : filtered
        return shown.sorted { left, right in
            let lhs = sort == .author ? left.author ?? "" : sort == .format ? left.format.displayName : left.title
            let rhs = sort == .author ? right.author ?? "" : sort == .format ? right.format.displayName : right.title
            let order = lhs.localizedStandardCompare(rhs)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }
    var selectedResource: LibraryResource? { resources.first { $0.id == selection } }
    var canPrepareOutput: Bool {
        ![.search,.collections,.favorites,.documents].contains(section) && reader.tab == .preview && !reader.isLoading &&
            selectedResource?.format == .legacyLSF && reader.currentLocation?.resourceID == selectedResource?.id
    }
    func prepareOutput(_ action: ReaderOutputAction) {
        guard canPrepareOutput, let resource = selectedResource, let location = reader.currentLocation else { return }
        output.prepare(resource:resource,location:location,selection:reader.selectedTextRange,action:action,window:window)
    }
    func openBibleCopy() {
        bibleCopy.open(resources:resources,current:selectedResource,reference:reader.currentLocation?.reference)
    }
    var recoveredCount: Int { resources.filter { $0.provenance == .legacyPublicMetadata }.count }
    var helpCount: Int { resources.filter(\.isHelp).count }
    func count(for section: LibrarySection) -> Int {
        switch section {
        case .all: resources.count
        case .recovered: recoveredCount
        case .help: helpCount
        case .collections: metadata?.collections.count ?? 0
        case .search: bookSearch.report?.results.count ?? 0
        case .favorites: store.personal.favorites.items.filter { $0.kind != .folder }.count
        case .documents: store.documents.documents.count
        }
    }
    func reconcileSelection() {
        if let pendingRestore, store.snapshot != nil {
            if let location = pendingRestore.location, location.resolve(in: resources) == nil {
                destinationError = "El recurso guardado no está en la biblioteca actual. Abre su carpeta para recuperar esta ventana."
                return
            }
            self.pendingRestore = nil
            if let location = pendingRestore.location { navigate(location, history: pendingRestore.history) }
            else if let selected = pendingRestore.selectedResourceID {
                if resources.contains(where: { $0.id == selected }) { selection = selected }
                else { selection = nil; destinationError = "El recurso guardado no está en la biblioteca actual. Vuelve a abrir su carpeta para recuperarlo." }
            }
            section = LibrarySection(rawValue: pendingRestore.section) ?? .all
            reader.tab = ReaderTab(rawValue: pendingRestore.readerTab) ?? .information
            if section == .search && !bookSearch.queryText.isEmpty { bookSearch.run(resources: resources, selectedResource: selectedResource) }
            return
        }
        guard selectedResource == nil else { return }
        selection = resources.first { $0.provenance == .legacyPublicMetadata }?.id ?? resources.first?.id
    }
    func openSearchResult(_ result: LibrarySearchResult) {
        cancelOriginalNavigation()
        guard let resource = resources.first(where: { $0.id == result.resourceID }) else { return }
        selection = resource.id
        section = .all
        reader.openSearchResult(result, resource: resource)
    }
    func navigate(_ location: ReaderLocation, history: ReadingHistory? = nil, selectionRange: SearchTextRange? = nil) {
        cancelOriginalNavigation()
        guard let resource = location.resolve(in: resources) else {
            destinationError = "El recurso de este destino no está disponible en la biblioteca actual. Se conserva el destino para recuperarlo."; return
        }
        guard resource.format == .legacyLSF else { destinationError = "Este formato todavía no admite navegación al contenido."; return }
        destinationError = nil; selection = resource.id; section = .all; reader.tab = .preview
        let position = selectionRange?.nsRange ?? location.characterOffset.map { NSRange(location: $0, length: 0) }
        if reader.currentLocation?.resourceID == resource.id {
            reader.load(location.sectionOrdinal, historyDestination: history, passageRange: position, expectedTextFingerprint: location.textFingerprint,
                        reference: location.reference, notifyLinks: false)
        } else {
            reader.open(resource, initialSection: location.sectionOrdinal, initialRange: position, expectedTextFingerprint: location.textFingerprint,
                        initialReference: location.reference, initialHistory: history)
        }
    }
    func workspaceState() -> WorkspaceWindowState {
        var state = WorkspaceWindowState(); state.id = id; state.location = reader.currentLocation
        if let pendingRestore { return pendingRestore }
        if state.location?.resourceID != selection { state.location = nil }
        state.selectedResourceID = selection; state.section = section.rawValue; state.catalogQuery = searchText
        state.catalogFormat = format; state.catalogSort = sort.rawValue; state.readerTab = reader.tab.rawValue
        state.linkGroup = linkGroup; state.history = state.location == nil ? ReadingHistory() : reader.history
        state.selectedDocumentID = selectedDocumentID; state.selectedNoteID = selectedNoteID
        state.search.query = bookSearch.queryText; state.search.allResources = bookSearch.searchAllResources
        state.search.caseSensitive = bookSearch.caseSensitive; state.search.diacriticSensitive = bookSearch.diacriticSensitive
        state.search.wholeWords = bookSearch.wholeWords; state.search.unit = bookSearch.unit.rawValue
        if let frame = window?.frame { state.frame = [frame.origin.x, frame.origin.y, frame.width, frame.height] }
        return state
    }
    func restore(_ state: WorkspaceWindowState) {
        restoring = true
        section = LibrarySection(rawValue: state.section) ?? .all; selection = state.selectedResourceID
        searchText = state.catalogQuery; format = state.catalogFormat; sort = CatalogSort(rawValue: state.catalogSort) ?? .title
        reader.tab = ReaderTab(rawValue: state.readerTab) ?? .information; linkGroup = state.linkGroup
        selectedDocumentID = state.selectedDocumentID; selectedNoteID = state.selectedNoteID
        bookSearch.queryText = state.search.query; bookSearch.searchAllResources = state.search.allResources
        bookSearch.caseSensitive = state.search.caseSensitive; bookSearch.diacriticSensitive = state.search.diacriticSensitive
        bookSearch.wholeWords = state.search.wholeWords; bookSearch.unit = LibrarySearchUnit(rawValue: state.search.unit) ?? .article
        pendingRestore = state; restoring = false
        restoredFrame = state.frame
        if let window { attachWindow(window) }
        reconcileSelection()
    }
    func attachWindow(_ window: NSWindow) {
        self.window = window
        if let frame = restoredFrame {
            let rectangle = NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
            window.setFrame(window.constrainFrameRect(rectangle, to: window.screen), display: true)
            restoredFrame = nil
        }
    }
    func addStudyNote(selection: Bool) {
        guard let location = reader.currentLocation else { return }
        let range = selection ? reader.selectedTextRange : nil
        guard !selection || (range?.length ?? 0) > 0 else { return }
        let target: UUID?
        if store.documents.document(selectedDocumentID)?.kind == .notebook { target = selectedDocumentID }
        else { target = store.documents.create(kind: .notebook, title: "Notas de estudio") }
        guard let target else { return }
        let note = StudyNote(title: location.reference ?? reader.currentTitle,
            anchor: StudyNoteAnchor(kind: selection ? .nativeSelection : .nativeReference, location: location, selection: range))
        store.documents.change(target) { $0.notes.append(note) }; store.documents.save(target)
        selectedDocumentID = target; selectedNoteID = note.id; section = .documents
    }
    func cancelOriginalNavigation() {
        originalLocatorTask?.cancel(); originalLocatorTask = nil
        originalLocatorGeneration += 1; isResolvingOriginalDestination = false
    }
    func navigateFavorite(_ favorite: LibraryFavorite) {
        cancelOriginalNavigation()
        if let location = favorite.location { navigate(location); return }
        guard favorite.kind == .legacyCommand, let command = favorite.legacyCommand else { return }
        do {
            let destination = try LegacyJumpDestination.parse(command)
            resolveOriginalDestination(resourceID: destination.resourceID, position: destination.position)
        } catch { destinationError = error.localizedDescription }
    }
    func navigateNote(_ note: StudyNote, documentID: UUID) {
        cancelOriginalNavigation()
        if let location = note.anchor.location { navigate(location, selectionRange: note.anchor.selection); return }
        guard note.anchor.kind == .legacySelection, let special = note.sourceAttributes["special"],
              let id = note.sourceAttributes["resource-id"] else {
            destinationError = "La referencia original de esta nota todavía necesita una traducción compatible."; return
        }
        let context = LegacyLocatorResolution.contextFields(special)
        guard let position = context["pos"] else { destinationError = "La nota no conserva una posición original compatible."; return }
        resolveOriginalDestination(resourceID: id, position: position, context: context) { [weak self] result in
            guard let self else { return }
            self.store.documents.changeNote(documentID, noteID: note.id) {
                $0.resolvedAnchor = StudyNoteAnchor(kind: .nativeSelection, location: result.location, selection: result.range)
            }
            self.store.documents.save(documentID)
        }
    }
    private func resolveOriginalDestination(resourceID: String, position: String, context: [String: String] = [:],
                                            didResolve: ((LegacyLocatorResolution) -> Void)? = nil) {
        cancelOriginalNavigation()
        let matches = resources.filter { $0.format == .legacyLSF && LegacyNumericResourceID.fromBKIDHex($0.legacyIdentifier)?.identifier == resourceID }
        guard matches.count == 1, let resource = matches.first else {
            destinationError = matches.isEmpty ? "El recurso de este destino no está disponible en un formato de lectura compatible."
                : "Hay varias copias de este recurso. Se conserva el destino hasta confirmar la edición."; return
        }
        let generation = originalLocatorGeneration
        isResolvingOriginalDestination = true; destinationError = nil
        originalLocatorTask = Task { [weak self, originalLocatorService] in
            do {
                let result = try await originalLocatorService.resolveArticleLocator(resource, originalResourceID: resourceID, position: position, context: context)
                try Task.checkCancellation()
                guard let self, self.originalLocatorGeneration == generation else { return }
                self.isResolvingOriginalDestination = false; self.originalLocatorTask = nil
                didResolve?(result)
                self.navigate(result.location, selectionRange: result.range)
            } catch is CancellationError { }
            catch {
                guard let self, self.originalLocatorGeneration == generation else { return }
                self.isResolvingOriginalDestination = false; self.originalLocatorTask = nil
                self.destinationError = error.localizedDescription
            }
        }
    }
    var readerAnnotations: [ReaderAnnotation] {
        guard let location = reader.currentLocation else { return [] }
        return store.documents.documents.flatMap { document in
            document.notes.compactMap { note in
                let anchor = note.effectiveAnchor
                guard let target = anchor.location, target.resourceID == location.resourceID,
                      target.legacyIdentifier == location.legacyIdentifier, target.sectionOrdinal == location.sectionOrdinal,
                      target.textFingerprint == location.textFingerprint else { return nil }
                return ReaderAnnotation(documentID: document.id, noteID: note.id, title: note.title, range: anchor.selection)
            }
        }
    }
    func openAnnotation(_ annotation: ReaderAnnotation) {
        selectedDocumentID = annotation.documentID; selectedNoteID = annotation.noteID; section = .documents
    }
    func chooseLibrary() { store.chooseLibrary() }
    func reload() { store.reload() }
    func cancelImport() { store.cancelImport() }
    func reveal(_ resource: LibraryResource) { NSWorkspace.shared.activateFileViewerSelecting([resource.location]) }
}
