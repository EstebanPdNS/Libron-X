import SwiftUI
import LibronixCore

struct AssociatedResourcesView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var controller: AssociationNavigationController
    @RebuildViewState private var selectionID: String?
    private var selectedMember: LibraryCollectionMember? { group?.members.first { $0.id == selectionID } }
    private var selectedResource: LibraryResource? { selectedMember.flatMap { group?.resolve($0, in: workspace.availableResources) } }
    private var canOpen: Bool { selectedResource != nil && !controller.isLoading && !(group?.relation == .alternatives && selectedResource == source?.resource) }
    private var source: ReaderSession? { workspace.readers.first { $0.id == controller.sourceID } }
    private var groups: [ResourceAssociationSet] {
        workspace.resourceAssociations.sets.filter { group in
            guard controller.sourceID != nil else { return true }
            return source.map { reader in group.members.contains { group.resolve($0, in: workspace.availableResources) == reader.resource } } ?? false
        }
    }
    private var group: ResourceAssociationSet? { groups.first { $0.id == controller.groupID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(L("Asociación"), selection: $controller.groupID) {
                    Text(L("Selecciona una asociación")).tag(Optional<UUID>.none)
                    ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(controller.isLoading)
                Button(L("Administrar asociaciones…")) { workspace.activeTool = .associations }
            }
            if let source { Text(LF("Origen: {title}", ["title": source.resource.title])).font(.callout).foregroundStyle(.secondary) }
            if let group {
                Text(L(group.relation.title)).font(.headline)
                HStack {
                    Picker(L("Destino"), selection: $controller.mode) {
                        ForEach(AssociationDestinationMode.allCases) { Text(L($0.title)).tag($0) }
                    }
                    if controller.mode != .start {
                        TextField(L("Referencia o entrada"), text: $controller.query).macInputStyle()
                    }
                }.disabled(controller.isLoading)
                Text(L(group.relation == .alternatives && source != nil
                       ? "Los alternativos reemplazan esta lectura después de comprobar el destino."
                       : group.relation == .companions ? "Los complementarios se abren en una lectura nueva."
                       : "El recurso se abrirá en una lectura nueva."))
                    .font(.caption).foregroundStyle(.secondary)
                if controller.mode == .start {
                    Text(L("Se abrirá el inicio del recurso; los números de artículo no se transfieren entre libros."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                List(group.members, selection: $selectionID) { member in
                    let resource = group.resolve(member, in: workspace.availableResources)
                    VStack(alignment: .leading) {
                        Text(resource?.title ?? member.title)
                        Text(resource?.fileName ?? L("Recurso no disponible o incompatible"))
                            .font(.caption).foregroundStyle(resource == nil ? .orange : .secondary)
                    }.padding(.vertical, 4).tag(member.id)
                }.accessibilityLabel(L("Recursos asociados"))
                HStack {
                    Button(L("Abrir selección")) { openSelection() }
                        .disabled(!canOpen).keyboardShortcut(.defaultAction)
                    if group.relation == .alternatives && source != nil {
                        Button(L("Lectura nueva")) { openSelection(newReader: true) }
                            .disabled(selectedResource == nil || controller.isLoading)
                    }
                }

            } else {
                Text(L("No hay una asociación disponible para esta lectura."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if controller.isLoading { HStack { ProgressView().controlSize(.small); Button(L("Cancelar")) { controller.cancel() } } }
            if let error = controller.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        }.padding(16)
            .onAppear { selectFirst() }
            .onChange(of: controller.groupID) { selectFirst() }
            .onDisappear { controller.cancel() }
    }
    private func selectFirst() {
        selectionID = group?.members.first(where: { group?.resolve($0, in: workspace.availableResources) != source?.resource })?.id ?? group?.members.first?.id
    }
    private func openSelection(newReader: Bool = false) {
        guard let member = selectedMember else { return }
        controller.open(member, workspace: workspace, newReader: newReader)
    }
}
