import AppKit
import Foundation
import LibronixCore
import Observation

/// Balance each acquired scope when its lease ends. Successful roots stay alive
/// until app exit because an independent reader can still use an older catalog.
private final class LibraryAccessLease {
    let url: URL
    private let acquired: Bool
    init(_ url: URL) {
        self.url = url
        acquired = url.startAccessingSecurityScopedResource()
    }
    deinit { if acquired { url.stopAccessingSecurityScopedResource() } }
}

/// Application lifetime owner of catalog imports and folder access. Window
/// presentation state is kept in LibraryModel; this store does not select books.
@MainActor @Observable final class LibraryStore {
    let personal: PersonalLibraryStore
    let documents: StudyDocumentsStore
    let printSettings: ReaderOutputSettingsStore
    let bibleCopySettings: BibleCopySettingsStore
    @ObservationIgnored private var windows: [UUID: WeakLibraryWindow] = [:]
    @ObservationIgnored private var pendingWindows: [String: WorkspaceWindowState] = [:]
    var snapshot: LibrarySnapshot?
    var metadata: MetadataSnapshot?
    var isImporting = false
    var progress: ImportProgress?
    var errorMessage: String?
    @ObservationIgnored private let importer = LibraryImporter()
    @ObservationIgnored private let metadataService = MetadataService()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var leases: [LibraryAccessLease] = []

    init(personalDirectory: URL? = nil) {
        personal = PersonalLibraryStore(directory: personalDirectory)
        documents = StudyDocumentsStore(directory: personalDirectory?.appendingPathComponent("Documents"))
        printSettings = ReaderOutputSettingsStore(directory: personalDirectory)
        bibleCopySettings = BibleCopySettingsStore(directory: personalDirectory)
    }
    var openModels: [LibraryModel] { windows.values.compactMap(\.model).sorted { $0.creationDate < $1.creationDate } }
    func register(_ model: LibraryModel) { windows[model.id] = WeakLibraryWindow(model) }
    func unregister(_ model: LibraryModel) { windows.removeValue(forKey: model.id) }
    func join(_ model: LibraryModel, group: ReaderLinkGroup) {
        guard group != .none else { return }
        if let reference = openModels.first(where: { $0 !== model && $0.linkGroup == group && $0.reader.committedReference != nil })?.reader.committedReference {
            model.reader.navigateToReference(reference, notifyLinks: false)
        }
    }
    func synchronize(_ location: ReaderLocation, from model: LibraryModel) {
        guard model.linkGroup != .none, let reference = location.reference, LegacyPassageQuery.parse(reference) != nil else { return }
        for target in openModels where target !== model && target.linkGroup == model.linkGroup && target.selectedResource?.format == .legacyLSF {
            target.reader.navigateToReference(reference, notifyLinks: false)
        }
    }
    func clearLinks() { for model in openModels { model.linkGroup = .none } }
    func workspace(name: String) -> WorkspaceDocument { WorkspaceDocument(name: name, windows: openModels.map { $0.workspaceState() }) }
    func enqueueWindow(_ state: WorkspaceWindowState) -> String {
        var state = state; state.id = UUID(); let key = state.id.uuidString
        pendingWindows[key] = state; return key
    }
    func saveWorkspace() {
        documents.flush()
        guard documents.unsavedIDs.isEmpty else { errorMessage = "Guarda los documentos pendientes antes de guardar el espacio de trabajo."; return }
        let panel = NSSavePanel(); panel.title = "Guardar espacio de trabajo"; panel.nameFieldStringValue = "Mi estudio.libronx-workspace"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let document = self.workspace(name: url.deletingPathExtension().lastPathComponent); try document.validate()
                let file = PersonalStateFile<WorkspaceDocument>(url: url)
                if let previous = try file.load() { try previous.validate() }
                try file.save(document)
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func loadWorkspace(openWindow: @escaping (String) -> Void) {
        let panel = NSOpenPanel(); panel.title = "Abrir espacio de trabajo de Libron-X"; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let document = try PersonalStateFile<WorkspaceDocument>(url: url).load() else { throw PersonalStateError.invalid("El archivo ya no existe.") }
                try document.validate()
                // Loading creates independent windows; existing study windows keep their state.
                for window in document.windows { openWindow(self.enqueueWindow(window)) }
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func takePendingWindow(_ key: String?) -> WorkspaceWindowState? { key.flatMap { pendingWindows.removeValue(forKey: $0) } }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Abrir tu biblioteca"
        panel.message = "Selecciona Resources o la carpeta que contiene tu biblioteca Libronix."
        panel.prompt = "Abrir biblioteca"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startImport(url)
        }
    }

    func reload() {
        guard let root = snapshot?.root else { return }
        startImport(root)
    }

    func cancelImport() {
        task?.cancel()
    }

    func restoreLibraryIfAvailable() {
        guard !restored else { return }
        restored = true
        let arguments = CommandLine.arguments
        if let offset = arguments.firstIndex(of: "--library"), offset + 1 < arguments.count {
            startImport(URL(fileURLWithPath: arguments[offset + 1]))
            return
        }
        // Preserve the folder chosen during the provisional app name.
        guard let data = UserDefaults.standard.data(forKey: "libraryBookmark.v1")
            ?? UserDefaults(suiteName: "org.bibliotecalibre.mac")?.data(forKey: "libraryBookmark.v1") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
            relativeTo: nil, bookmarkDataIsStale: &stale) {
            startImport(url)
        }
    }

    func startImport(_ url: URL) {
        task?.cancel()
        generation += 1
        let request = generation
        isImporting = true
        progress = nil
        errorMessage = nil
        let lease = LibraryAccessLease(url)
        task = Task { [weak self, importer, metadataService, lease] in
            do {
                async let metadataCandidate = metadataService.inspect(at: url)
                let next = try await importer.importDirectory(at: url) { [weak self] value in
                    await MainActor.run {
                        guard let self, self.generation == request else { return }
                        self.progress = value
                    }
                }
                let nextMetadata = try await metadataCandidate
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                if !self.leases.contains(where: { $0.url == lease.url }) { self.leases.append(lease) }
                self.snapshot = next
                self.metadata = nextMetadata
                self.isImporting = false
                self.progress = nil
                if let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(bookmark, forKey: "libraryBookmark.v1")
                }
            } catch is CancellationError {
                guard let self, self.generation == request else { return }
                self.isImporting = false
                self.progress = nil
            } catch {
                guard let self, self.generation == request else { return }
                self.errorMessage = error.localizedDescription
                self.isImporting = false
                self.progress = nil
            }
        }
    }

}

@MainActor private final class WeakLibraryWindow {
    weak var model: LibraryModel?
    init(_ model: LibraryModel) { self.model = model }
}
