import Foundation
import Observation
import LibronixCore

struct RecentWorkspaceSnapshot: Codable {
    var schemaVersion = 1
    var urls: [URL] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw PersonalStateError.futureVersion }
        guard urls.count <= 10, Set(urls).count == urls.count,
              urls.allSatisfy({ Self.isLocalFile($0) && $0 == $0.standardizedFileURL }) else {
            throw PersonalStateError.invalid(AppStrings.text("La lista de áreas recientes contiene entradas incompatibles.", language: .saved()))
        }
    }
    static func isLocalFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
        url.query == nil && url.fragment == nil && url.path.hasPrefix("/") &&
        !url.path.contains("\0") && url.path.utf8.count <= 16_384
    }
}

/// Owned MRU metadata only. Clearing this list never removes a workspace file.
@MainActor @Observable final class RecentWorkspaces {
    private(set) var urls: [URL] = []
    private(set) var loadError: String?
    @ObservationIgnored private let file: PersonalStateFile<RecentWorkspaceSnapshot>
    @ObservationIgnored private var canSave = false
    init(url: URL? = nil) {
        let path = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.libronx.mac.rebuild/recent-workspaces.json")
        file = PersonalStateFile(url: path)
        do { try reload() } catch { loadError = error.localizedDescription }
    }
    func record(_ url: URL) throws {
        guard RecentWorkspaceSnapshot.isLocalFile(url) else { throw PersonalStateError.invalid(L("Elige un archivo local de área de trabajo.")) }
        let normalized = url.standardizedFileURL
        try commit(Array(([normalized] + urls.filter { $0 != normalized }).prefix(10)))
    }
    func remove(_ url: URL) throws { try commit(urls.filter { $0 != url.standardizedFileURL }) }
    func clear() throws { try commit([]) }
    /// Runs at native menu tracking boundaries, not during reading/layout.
    /// Reload first so another instance's valid list is not overwritten.
    func refreshPruningMissingFiles() throws {
        do {
            try reload()
            let retained = urls.filter { url in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
            }
            try commit(retained)
        } catch { loadError = error.localizedDescription; throw error }
    }
    static func title(for url: URL) -> String {
        let file = url.lastPathComponent
        return file.lowercased().hasSuffix(".libronx.json") ? String(file.dropLast(".libronx.json".count)) : url.deletingPathExtension().lastPathComponent
    }
    func menuTitle(for url: URL) -> String {
        let title = Self.title(for: url)
        return urls.filter { Self.title(for: $0) == title }.count > 1 ? title + " — " + url.deletingLastPathComponent().path : title
    }
    private func reload() throws {
        canSave = false
        let saved = try file.load() ?? RecentWorkspaceSnapshot()
        try saved.validate(); urls = saved.urls; canSave = true; loadError = nil
    }
    private func commit(_ next: [URL]) throws {
        guard canSave else { throw PersonalStateError.invalid(loadError ?? L("No se pudo leer la lista de áreas recientes.")) }
        guard next != urls else { return }
        let snapshot = RecentWorkspaceSnapshot(urls: next)
        try snapshot.validate(); try file.save(snapshot)
        urls = next; loadError = nil
    }
}

enum WorkspaceFileFailure: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { AppStrings.text("El archivo del área de trabajo ya no está disponible.", language: .saved()) }
}
