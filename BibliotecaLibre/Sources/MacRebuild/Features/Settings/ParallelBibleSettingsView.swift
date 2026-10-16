import SwiftUI
import LibronixCore

struct ParallelBibleSettingsView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var selectedSetID: UUID?
    @RebuildViewState private var selectedMemberID: String?
    @RebuildViewState private var name = ""
    @RebuildViewState private var available: [LibraryResource] = []
    @RebuildViewState private var loading = false
    @RebuildViewState private var error: String?
    private var sets: ParallelBibleSets { workspace.parallelBibleSets }
    private var selected: ParallelBibleSet? { sets.sets.first { $0.id == selectedSetID } }
    private var resources: [LibraryResource] { workspace.availableResources }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Grupos de Biblias paralelas")).font(.headline)
            Text(L("Elige las Biblias y su orden. Las flechas recorren el grupo elegido en cada lectura y conservan el versículo."))
                .font(.callout).foregroundStyle(.secondary)
            HSplitView {
                VStack(spacing: 8) {
                    List(sets.sets, selection: $selectedSetID) { set in
                        VStack(alignment: .leading) {
                            Text(set.name)
                            Text(LF("{count} recursos", ["count": String(set.members.count)])).font(.caption).foregroundStyle(.secondary)
                        }.tag(set.id)
                    }.accessibilityLabel(L("Grupos de Biblias paralelas"))
                    HStack {
                        Button(L("Nuevo grupo"), systemImage: "plus") {
                            perform { selectedSetID = try sets.create() }
                        }
                        Button(L("Eliminar grupo"), systemImage: "minus") {
                            if let id = selectedSetID { perform { try sets.remove(id); selectedSetID = sets.sets.first?.id } }
                        }.labelStyle(.iconOnly).help(L("Eliminar grupo")).disabled(selected == nil)
                    }.controlSize(.small)
                }.frame(minWidth: 160, idealWidth: 190, maxWidth: 230)
                VStack(alignment: .leading, spacing: 10) {
                    if let selected {
                        HStack {
                            TextField(L("Nombre del grupo"), text: $name).macInputStyle()
                                .onSubmit { perform { try sets.rename(selected.id, to: name) } }
                            Button(L("Guardar")) { perform { try sets.rename(selected.id, to: name) } }
                                .disabled(name == selected.name)
                        }
                        List(selected.members, selection: $selectedMemberID) { member in
                            VStack(alignment: .leading) {
                                Text(member.title).lineLimit(2)
                                Text(member.resolve(in: resources)?.fileName ?? L("Recurso no disponible"))
                                    .font(.caption).foregroundStyle(member.resolve(in: resources) == nil ? .orange : .secondary)
                            }.tag(member.id)
                        }.accessibilityLabel(L("Orden de las Biblias"))
                        HStack {
                            Menu {
                                ForEach(available.filter { resource in !selected.members.contains { $0.id == resource.id } }) { resource in
                                    Button(parallelBibleMenuTitle(resource, in: available)) { perform { try sets.add(resource, to: selected.id); selectedMemberID = resource.id } }
                                }
                            } label: { Label(L("Agregar Biblia"), systemImage: "plus") }
                                .disabled(loading || available.allSatisfy { resource in selected.members.contains { $0.id == resource.id } })
                            Button(L("Quitar del grupo"), systemImage: "minus") {
                                if let member = selectedMemberID { perform { try sets.removeMember(member, from: selected.id); selectedMemberID = nil } }
                            }.labelStyle(.iconOnly).help(L("Quitar del grupo")).disabled(selectedMemberID == nil)
                            Spacer()
                            Button(L("Subir"), systemImage: "chevron.up") { move(-1) }.labelStyle(.iconOnly).help(L("Subir")).disabled(!canMove(-1))
                            Button(L("Bajar"), systemImage: "chevron.down") { move(1) }.labelStyle(.iconOnly).help(L("Bajar")).disabled(!canMove(1))
                        }.controlSize(.small)
                        Text(L("Los cambios de orden se guardan al instante. Quitar un recurso del grupo no borra su archivo."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("Crea un grupo para elegir sus Biblias.")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(.leading, 10).frame(minWidth: 350)
            }
            if loading { ProgressView(L("Leyendo las Biblias disponibles…")).controlSize(.small) }
            if let error = error ?? sets.loadError {
                HStack {
                    Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button(L("Volver a cargar")) { perform { try sets.reload() } }
                }
            }
        }.padding(20)
        .onAppear { selectedSetID = selectedSetID ?? sets.sets.first?.id; name = selected?.name ?? "" }
        .onChange(of: selectedSetID) { name = selected?.name ?? ""; selectedMemberID = nil }
        .task(id: resources.map(\.id)) {
            loading = true
            defer { loading = false }
            do {
                let next = try await workspace.bibleVersionCatalog.versions(in: resources, observed: Set(workspace.bibleReaders.map { $0.resource.id }))
                guard !Task.isCancelled else { return }; available = next
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func canMove(_ delta: Int) -> Bool {
        guard let selected, let index = selected.members.firstIndex(where: { $0.id == selectedMemberID }) else { return false }
        return selected.members.indices.contains(index + delta)
    }
    private func move(_ delta: Int) {
        guard let id = selectedSetID, let member = selectedMemberID else { return }
        perform { try sets.moveMember(member, in: id, by: delta) }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
