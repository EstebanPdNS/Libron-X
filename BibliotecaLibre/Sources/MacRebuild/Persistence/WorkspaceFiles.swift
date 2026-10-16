import AppKit
import UniformTypeIdentifiers
import LibronixCore

struct WorkspaceArchive: Codable {
    struct Pane: Codable {
        var resource: LibraryResource
        var destination: ReaderDestination?
        var fingerprint: String?
        var frame: PaneFrame
        var minimized: Bool
        var maximized: Bool
        var contents: Bool
        var locator: Bool
        var articleLocator: Bool
        var scale: Double
        var selection: NSRange
        var history: [ReaderDestination]
        var historyIndex: Int
        var link: ReaderLinkGroup
        var interlinearLines: [Int]? = nil
        var viewportOffset: Int? = nil
        var parallelSetID: UUID? = nil
    }
    var schemaVersion = 1
    var libraryRoot: URL?
    var resources: [LibraryResource]
    var panes: [Pane]
    var activeIndex: Int?
    var referenceTargetIndex: Int?
    var showsHome: Bool? = nil
    /// Pane records retain stacking order. This permutation preserves the
    /// independent opening order used by the Window menu and keyboard cycling.
    /// Missing in earlier schema-1 files: their stored pane order is retained.
    var openingOrder: [Int]? = nil
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard libraryRoot?.isFileURL != false, panes.count <= 100, resources.count <= 50_000, Set(resources.map(\.id)).count == resources.count,
              resources.allSatisfy({ $0.location.isFileURL && $0.id == $0.location.standardizedFileURL.path }),
              activeIndex.map({ panes.indices.contains($0) }) ?? true,
              referenceTargetIndex.map({ panes.indices.contains($0) }) ?? true,
              openingOrder.map({ $0.count == panes.count && Set($0) == Set(panes.indices) }) ?? true
              else { throw PersonalStateError.invalid("El área de trabajo contiene ventanas o recursos incompatibles.") }
        for pane in panes {
            try pane.destination?.validate()
            for destination in pane.history { try destination.validate() }
            let f = pane.frame
            guard pane.resource.location.isFileURL, pane.destination.map({ $0.ordinal >= 0 }) ?? true,
                  [f.x,f.y,f.width,f.height,pane.scale].allSatisfy(\.isFinite),
                  f.x >= 0, f.y >= 0, f.width > 0, f.height > 0, f.x + f.width <= 1.000001, f.y + f.height <= 1.000001,
                  (0.5...3).contains(pane.scale), pane.history.count <= 10_000,
                  (-1..<pane.history.count).contains(pane.historyIndex), pane.history.allSatisfy({ $0.ordinal >= 0 }),
                  pane.selection.location >= 0, pane.selection.length >= 0,
                  pane.selection.location <= Int.max - pane.selection.length,
                  pane.viewportOffset.map({ $0 >= 0 }) ?? true,
                  pane.interlinearLines.map({ !$0.isEmpty && $0.count <= 32 && $0.allSatisfy { (0..<32).contains($0) } }) ?? true else { throw PersonalStateError.invalid("Un lector del área de trabajo contiene posiciones inválidas.") }
        }
    }
}

@MainActor extension StudyWorkspace {
    func archive() -> WorkspaceArchive {
        WorkspaceArchive(libraryRoot: libraryRoot, resources: resources,
            panes: readers.map { reader in .init(resource: reader.resource, destination: reader.committedPage?.destination,
                fingerprint: reader.committedPage.flatMap { page in page.oeb != nil && !reader.committedOEBProjectionReady ? nil : LibrarySearchService.textFingerprint(page.text) }, frame: reader.frame,
                minimized: reader.isMinimized, maximized: reader.isMaximized, contents: reader.showsContents,
                locator: reader.showsLocator, articleLocator: reader.locatorIsArticle, scale: reader.textScale, selection: reader.committedSelection,
                history: reader.history, historyIndex: reader.historyIndex, link: reader.linkGroup,
                interlinearLines: reader.visibleInterlinearLines?.sorted(), viewportOffset: reader.viewportCharacterOffset, parallelSetID: reader.parallelSetID) },
            activeIndex: readers.firstIndex { $0.id == activeID }, referenceTargetIndex: readers.firstIndex { $0.id == referenceTargetID }, showsHome: showsHome,
            openingOrder: orderedReaders.compactMap { reader in readers.firstIndex { $0 === reader } })
    }
    func restore(_ saved: WorkspaceArchive) throws {
        try saved.validate()
        cancelImport(); closeAll(); resources = saved.resources; libraryRoot = saved.libraryRoot
        for pane in saved.panes {
            let reader = open(pane.resource, startReading: false)
            reader.frame = pane.frame; reader.isMinimized = pane.minimized; reader.isMaximized = pane.maximized
            reader.showsContents = pane.contents; reader.showsLocator = pane.locator
            reader.locatorIsArticle = pane.articleLocator; reader.textScale = pane.scale; reader.linkGroup = pane.link
            reader.parallelSetID = pane.parallelSetID
            reader.visibleInterlinearLines = pane.interlinearLines.map(Set.init)
            reader.history = pane.history; reader.historyIndex = pane.historyIndex
            if let destination = pane.destination {
                reader.load(destination, historyTarget: pane.historyIndex >= 0 ? pane.historyIndex : nil,
                            propagateReference: false, selection: pane.selection, expectedFingerprint: pane.fingerprint, viewportOffset: pane.viewportOffset)
            }
        }
        readerOrder = (saved.openingOrder ?? Array(saved.panes.indices)).map { readers[$0].id }
        activeID = saved.activeIndex.map { readers[$0].id } ?? visibleReaders.last?.id
        referenceTargetID = saved.referenceTargetIndex.map { readers[$0].id }
        showsHome = saved.showsHome ?? false
    }
    func saveWorkspace() {
        let panel = NSSavePanel(); panel.title = L("Guardar área de trabajo")
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Área de trabajo.libronx.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.saveWorkspace(to: url)
            } catch { self.error = error.localizedDescription }
        }
    }
    func openWorkspace() {
        let panel = NSOpenPanel(); panel.title = L("Cargar área de trabajo"); panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.loadWorkspace(at: url)
            } catch { self.error = error.localizedDescription }
        }
    }
    func saveWorkspace(to url: URL) throws {
        guard RecentWorkspaceSnapshot.isLocalFile(url) else { throw PersonalStateError.invalid(L("Elige un archivo local de área de trabajo.")) }
        let state = archive(); try state.validate()
        let file = PersonalStateFile<WorkspaceArchive>(url: url)
        if let previous = try file.load() { try previous.validate() }
        try file.save(state)
        do { try recentWorkspaces.record(url) }
        catch { self.error = LF("El área de trabajo se guardó, pero no se pudo actualizar la lista de recientes: {error}", ["error": error.localizedDescription]) }
    }
    func loadWorkspace(at url: URL) throws {
        guard RecentWorkspaceSnapshot.isLocalFile(url) else { throw PersonalStateError.invalid(L("Elige un archivo local de área de trabajo.")) }
        do {
            let file = PersonalStateFile<WorkspaceArchive>(url: url)
            guard let state = try file.load() else { throw WorkspaceFileFailure.unavailable }
            try restore(state)
        } catch {
            // Failed recent entries are removed, never the underlying file.
            try? recentWorkspaces.remove(url); throw error
        }
        do { try recentWorkspaces.record(url) }
        catch { self.error = LF("El área de trabajo se cargó, pero no se pudo actualizar la lista de recientes: {error}", ["error": error.localizedDescription]) }
    }
    func openRecentWorkspace(_ url: URL) {
        do { try loadWorkspace(at: url) } catch { self.error = error.localizedDescription }
    }
    func clearRecentWorkspaces() {
        do { try recentWorkspaces.clear() } catch { self.error = error.localizedDescription }
    }
    func newDocument(_ kind: StudyDocumentKind) { personal.create(kind); activeTool = .documents }
    func openDocument() {
        let panel = NSOpenPanel(); panel.title = L("Documento de estudio…"); panel.allowsOtherFileTypes = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 16 * 1024 * 1024 else { throw PersonalStateError.tooLarge }
                let bytes = try Data(contentsOf: url)
                var document: StudyDocument
                if url.pathExtension.lowercased() == "json" { document = try JSONDecoder().decode(StudyDocument.self, from: bytes) }
                else { document = try StudyDocument.importingLegacyXML(bytes) }
                try document.validate()
                if self.personal.documents.contains(where: { $0.id == document.id }) { document.id = UUID() }
                self.personal.documents.append(document); self.personal.selectedDocumentID = document.id
                self.savePersonal(); self.activeTool = .documents
            } catch { self.error = error.localizedDescription }
        }
    }
    func exportDocument(_ document: StudyDocument) {
        let panel = NSSavePanel(); panel.title = L("Guardar como…"); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = document.title + ".json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try document.validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(document).write(to: url, options: .atomic) }
            catch { self?.error = error.localizedDescription }
        }
    }
}
