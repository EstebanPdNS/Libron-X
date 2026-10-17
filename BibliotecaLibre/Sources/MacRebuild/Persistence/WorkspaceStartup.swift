import Foundation
import LibronixCore

/// The auto-recovery copy is a separate owned personal file. Loading and
/// validation happen before any save; a damaged/future copy is never replaced.
@MainActor final class WorkspaceStartupStore {
    private let file: PersonalStateFile<WorkspaceArchive>
    private var canSave = false
    init(url: URL? = nil) {
        let path = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/last-workspace.json")
        file = PersonalStateFile(url: path)
    }
    func load() throws -> WorkspaceArchive? {
        canSave = false
        let saved = try file.load()
        try saved?.validate()
        canSave = true
        return saved
    }
    func save(_ archive: WorkspaceArchive) throws {
        guard canSave else { throw PersonalStateError.invalid("No se pudo validar el área de trabajo anterior; se ha conservado su archivo.") }
        try archive.validate(); try file.save(archive)
    }
}

@MainActor final class WorkspaceStartupCoordinator {
    let store: WorkspaceStartupStore
    private var started = false
    init(store: WorkspaceStartupStore = WorkspaceStartupStore()) { self.store = store }
    /// Returns a request to open the native library scene. The coordinator
    /// itself never opens windows, making startup effects explicit and testable.
    @discardableResult func launch(_ workspace: StudyWorkspace, preferences: AppPreferences,
                                   arguments: [String] = CommandLine.arguments) -> Bool {
        guard !started else { return false }
        started = true
        var previous: WorkspaceArchive?
        do { previous = try store.load() }
        catch { previous = nil; workspace.error = error.localizedDescription }
        let managedRoot = LibraryPreferences.shared.directory
        if FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("catalog.json").path) {
            do {
                let managed = try LibronCatalog.load(from: managedRoot)
                if var saved = previous {
                    let byID = Dictionary(uniqueKeysWithValues: managed.resources.map { ($0.id, $0) })
                    saved.resources = managed.resources; saved.libraryRoot = managedRoot
                    for index in saved.panes.indices {
                        if let resource = byID[saved.panes[index].resource.id] { saved.panes[index].resource = resource }
                    }
                    previous = saved
                } else { workspace.resources = managed.resources; workspace.libraryRoot = managedRoot }
            } catch { workspace.error = error.localizedDescription }
        }
        if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            workspace.importLibrary(URL(fileURLWithPath: arguments[index + 1])); return false
        }
        if let previous {
            workspace.resources = previous.resources; workspace.libraryRoot = previous.libraryRoot
        }
        do {
            switch preferences.startup {
            case .restorePrevious:
                if let previous { try workspace.restore(previous) }
                else { workspace.showsHome = true }
            case .blank: workspace.showsHome = false
            case .home: workspace.showsHome = true
            case .library: return true
            case .workspace:
                guard let url = preferences.startupWorkspaceURL else {
                    throw PersonalStateError.invalid("Elige un área de trabajo en Ajustes para abrirla al iniciar.")
                }
                try workspace.loadWorkspace(at: url)
            }
        } catch { workspace.error = error.localizedDescription }
        return false
    }
    func save(_ workspace: StudyWorkspace) throws { try store.save(workspace.archive()) }
}
