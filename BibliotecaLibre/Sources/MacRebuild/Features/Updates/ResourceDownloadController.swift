import Foundation
import Observation
import LibronixCore

struct ResourceDownloadRow: Identifiable {
    let id: String
    let title: String
    var progress = 0.0
    var status = "Pendiente"
    var outcome: ResourceDownloadOutcome?
    var detail: String?
}
@MainActor @Observable final class ResourceDownloadController {
    static let shared = ResourceDownloadController()
    var codeText = ""
    private(set) var rows: [ResourceDownloadRow] = []
    private(set) var collectionTitle = ""
    private(set) var isBusy = false
    private(set) var status = ""
    private(set) var error: String?
    private(set) var result: ResourceDownloadResult?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var indices: [String: Int] = [:]
    var finishedCount: Int { rows.filter { $0.outcome != nil }.count }
    func start(in root: URL, didChange: @escaping @MainActor (Set<String>) -> Void) {
        guard !isBusy else { return }
        let code: ResourceDownloadCode
        do { code = try ResourceDownloadCode.decode(codeText) }
        catch { self.error = error.localizedDescription; return }
        generation += 1; let token = generation
        rows = []; indices = [:]; collectionTitle = ""; result = nil; error = nil; isBusy = true
        status = "Leyendo el paquete de descarga…"
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("org.libronx.mac.rebuild/resource-downloads", isDirectory: true)
        let installer = ResourcePackageInstaller(root: root, cache: cache)
        task = Task { [weak self] in
            var hidden: Set<String> = []
            do {
                let result = try await installer.install(code) { [weak self] event in
                    await self?.receive(event, generation: token)
                }
                hidden = result.hiddenIDs
                guard let self, self.generation == token else { return }
                self.result = result; self.status = "Descarga finalizada"
            } catch is CancellationError { self?.status = "Descarga cancelada. Puedes volver a usar el mismo código para continuar." }
            catch { self?.error = error.localizedDescription; self?.status = "No se pudo completar la descarga" }
            guard let self, self.generation == token else { return }
            self.isBusy = false
            didChange(hidden)
        }
    }
    func cancel() { task?.cancel() }
    private func receive(_ event: ResourceDownloadEvent, generation token: Int) {
        guard token == generation else { return }
        switch event {
        case let .collection(title, entries):
            collectionTitle = title; rows = entries.map { ResourceDownloadRow(id: $0.id, title: $0.title) }
            indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            status = "Descargando recursos"
        case let .progress(id, fraction, text):
            guard let index = indices[id], rows[index].outcome == nil else { return }
            rows[index].progress = max(rows[index].progress, min(1, max(0, fraction)))
            rows[index].status = text
        case let .finished(id, outcome, detail):
            guard let index = indices[id] else { return }
            rows[index].outcome = outcome; rows[index].progress = 1; rows[index].detail = detail
            switch outcome {
            case .new: rows[index].status = "Nuevo · instalado"
            case .updated: rows[index].status = "Actualizado"
            case .installed: rows[index].status = "Ya instalado · sin descargar"
            case .failed: rows[index].status = "No se pudo descargar"
            }
        }
    }
}
@MainActor extension StudyWorkspace {
    func reloadDownloadedResources(at root: URL, hiddenIDs: Set<String>) {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path) else { return }
        do {
            let loaded = try LibronCatalog.load(from: root).resources
            let other = resources.filter { resource in
                guard let package = resource.packageLocation else { return true }
                return package.deletingLastPathComponent().standardizedFileURL != root.standardizedFileURL
            }
            let replacements = Set(loaded.map(\.id))
            resources = other.filter { !replacements.contains($0.id) } + loaded
            includeBundledDictionaries(); libraryRoot = root
            if !hiddenIDs.isEmpty { try hideLibraryResources(hiddenIDs.intersection(Set(resources.map(\.id)))) }
            search.clear(); keyLinks.clear(); referenceSearch.clear()
        } catch { self.error = error.localizedDescription }
    }
}
