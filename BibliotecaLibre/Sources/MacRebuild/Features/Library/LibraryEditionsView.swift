import SwiftUI
import Observation
import LibronixCore

@MainActor @Observable final class LibraryEditionsController {
    private(set) var report: LibraryEditionAudit?
    private(set) var isLoading = false
    private(set) var error: String?
    var groupID: String?
    var resourceID: String?
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var generation = 0
    func cancel() { generation += 1; task?.cancel(); task = nil; isLoading = false }
    func scan(_ resources: [LibraryResource]) {
        cancel(); let token = generation; isLoading = true; error = nil
        task = Task { [weak self] in
            let job = Task.detached { try LibraryEditionAudit.scan(resources) }
            do {
                let result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.report = result; self.groupID = result.groups.first?.id; self.resourceID = nil; self.isLoading = false
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func setHidden(_ hidden: Bool, resource: LibraryResource, workspace: StudyWorkspace) throws {
        guard !isLoading, report?.resources == workspace.resources, workspace.resources.contains(resource) else { throw PersonalStateError.invalid(L("El catálogo cambió. Analiza la biblioteca de nuevo.")) }
        if hidden { try workspace.hideLibraryResources([resource.id]) }
        else { try workspace.restoreLibraryResources([resource.id]) }
    }
    deinit { task?.cancel() }
}

struct LibraryEditionsView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var controller: LibraryEditionsController
    private var group: LibraryEditionGroup? { controller.report?.groups.first { $0.id == controller.groupID } }
    private var resource: LibraryResource? { group?.resources.first { $0.id == controller.resourceID } }
    private var stale: Bool { controller.report?.resources != workspace.resources }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Button(L("Analizar biblioteca")) { controller.scan(workspace.resources) }.disabled(controller.isLoading)
                if controller.isLoading { ProgressView().controlSize(.small);Button(L("Cancelar")) { controller.cancel() } }
                Spacer()
                if let report = controller.report { Text(LF("{count} recursos",["count":String(report.examined)])).foregroundStyle(.secondary) }
            }
            Text(L("Las copias exactas se comprueban por contenido. Las ediciones posibles requieren revisión. Ocultar es reversible."))
                .font(.caption).foregroundStyle(.secondary)
            if let report = controller.report {
                if stale { Text(L("El catálogo cambió. Analiza la biblioteca de nuevo.")).foregroundStyle(.orange) }
                HSplitView {
                    List(report.groups,selection:$controller.groupID) { group in
                        VStack(alignment:.leading) {
                            Text(L(group.kind.title)).font(.headline)
                            Text(group.resources.first?.title ?? "").lineLimit(2)
                            Text(LF("{count} recursos",["count":String(group.resources.count)])).font(.caption).foregroundStyle(.secondary)
                        }.tag(group.id)
                    }.frame(minWidth:220)
                    List(group?.resources ?? [],selection:$controller.resourceID) { resource in
                        VStack(alignment:.leading,spacing:4) {
                            Text(resource.title)
                            Text([resource.libron?.edition,resource.libron?.year,resource.libron?.publisher,resource.languages.joined(separator:", ")].compactMap { $0 }.joined(separator:" · ")).font(.caption)
                            Text(resource.location.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            if workspace.resourceVisibility.isHidden(resource) { Text(L("Oculto")).font(.caption).foregroundStyle(.secondary) }
                        }.tag(resource.id)
                    }.frame(minWidth:340)
                }.frame(minHeight:260)
                if report.groups.isEmpty { Text(L("No se encontraron duplicados ni ediciones coincidentes.")).foregroundStyle(.secondary) }
                if let resource {
                    HStack {
                        Button(L("Abrir recurso")) { workspace.open(resource);workspace.activeTool = nil }
                        Button(L(workspace.resourceVisibility.isHidden(resource) ? "Volver a mostrar" : "Ocultar recurso")) {
                            do { try controller.setHidden(!workspace.resourceVisibility.isHidden(resource),resource:resource,workspace:workspace) }
                            catch { workspace.error = error.localizedDescription }
                        }.disabled(stale || controller.isLoading)
                        Button(L("Copiar cita del recurso")) { ResourceCitationActions.copy([resource]) }
                    }
                }
                if !report.issues.isEmpty {
                    DisclosureGroup(L("Recursos pendientes")) { ScrollView { Text(report.issues.joined(separator:"\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight:90) }
                }
            } else { Spacer();Text(L("Analiza la biblioteca para comparar copias y ediciones.")).foregroundStyle(.secondary);Spacer() }
            if let error=controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(16).onDisappear { controller.cancel() }
    }
}

extension LibraryEditionGroup.Kind {
    var title: String { switch self { case .exactCopies: "Copias exactas";case .differentReaders: "Mismo original, distinto contenido nativo";case .possibleEditions: "Posibles ediciones" } }
}
