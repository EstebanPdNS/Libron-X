import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LibronixCore

struct ResourceAssociationImportView: View {
    let workspace: StudyWorkspace
    let onImported: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var document: ResourceAssociationDocument?
    @RebuildViewState private var relation = AssociationRelation.alternatives
    @RebuildViewState private var kind = AssociationResourceKind.series
    @RebuildViewState private var loading = false
    @RebuildViewState private var error: String?
    @RebuildViewState private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            MacToolHeader(title: "Importar asociación original") { task?.cancel(); dismiss() }
            Button(L("Elegir archivo .lbxras…"),action:choose).disabled(loading)
            if let document {
                Text(document.definition.title).font(.title3).textSelection(.enabled)
                Text(document.source.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                Text(LF("{groups} grupos · {members} referencias de recursos",[
                    "groups":String(document.definition.groups.count),"members":String(document.definition.resourceIDs.count)]))
                Picker(L("Relación"),selection:$relation) {
                    ForEach(AssociationRelation.allCases) { Text(L($0.title)).tag($0) }
                }
                Picker(L("Tipo"),selection:$kind) {
                    ForEach(AssociationResourceKind.allCases) { Text(L($0.title)).tag($0) }
                }
                Text(L("En una serie importada, la pertenencia declarada por el original determina los recursos compatibles."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("Se conservarán el documento original, su procedencia, el orden y los miembros ausentes. La relación elegida se aplicará a todos los grupos del archivo."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Importar")) {
                    do {
                        let ids = try workspace.resourceAssociations.importOriginal(document,relation:relation,kind:kind,resources:workspace.availableResources)
                        if let id = ids.first { onImported(id) }; dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(document.definition.groups.isEmpty || loading)
            } else { Text(L("Selecciona una definición de asociación de Libronix.")).foregroundStyle(.secondary) }
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        }.padding(20).frame(width:540).modifier(MacPanelControlPresentation())
            .onDisappear { task?.cancel() }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension:"lbxras") ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            task?.cancel(); loading = true; error = nil; document = nil
            task = Task { @MainActor in
                defer { loading = false }
                let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let result = try await Task.detached { try MetadataImporter.readAssociation(at:url) }.value
                    guard !Task.isCancelled else { return }; document = result
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }
}
