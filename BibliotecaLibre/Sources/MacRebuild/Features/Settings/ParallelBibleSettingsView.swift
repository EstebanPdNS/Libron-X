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
    private var selected: ParallelBibleSet? { workspace.bibleGroups.first { $0.id == selectedSetID } }
    private var resources: [LibraryResource] { workspace.availableResources }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Grupos de Biblias paralelas")).font(.headline)
            }.padding(.horizontal, 20)
            DisclosureGroup(L("Grupo de diccionarios")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(workspace.dictionaryGroup) { resource in Text(resource.title).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.frame(maxHeight: 120)
            }.padding(.horizontal, 20)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    List(workspace.bibleGroups, selection: $selectedSetID) { set in
                        VStack(alignment: .leading) {
                            Text(set.name)
                            Text(LF("{count} recursos", ["count": String(set.members.count)])).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                            .tag(set.id)
                            .contextMenu {
                                Button(L("Eliminar grupo"), systemImage: "trash", role: .destructive) { removeGroup(set.id) }
                            }
                    }
                    .listStyle(.inset)
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                    .accessibilityLabel(L("Grupos de Biblias paralelas"))
                    Button {
                        perform { selectedSetID = try sets.create() }
                    } label: {
                        Label(L("Nuevo grupo"), systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .labelStyle(.titleAndIcon).controlSize(.small)
                    .padding(.bottom, 8)
                }
                // The sidebar spans from the window edge to its divider. Both
                // controls share symmetric insets, independent of header margins.
                .padding(.horizontal, 8)
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 230)

                VStack(alignment: .leading, spacing: 10) {
                    if let selected {
                        HStack {
                            Text(L("Nombre del grupo")).font(.headline)
                            Spacer()
                            Menu {
                                Button(L("Eliminar grupo"), systemImage: "trash", role: .destructive) { removeGroup(selected.id) }
                            } label: { Label(L("Acciones del grupo"), systemImage: "ellipsis.circle") }
                                .labelStyle(.iconOnly).menuIndicator(.hidden).controlSize(.small)
                                .help(L("Acciones del grupo"))
                        }
                        HStack {
                            TextField(L("Nombre del grupo"), text: $name).macInputStyle()
                                .onSubmit { perform { try sets.rename(selected.id, to: name) } }.disabled(selected.automaticLanguage != nil)
                            Button(L("Guardar")) { perform { try sets.rename(selected.id, to: name) } }
                                .disabled(name == selected.name || selected.automaticLanguage != nil)
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
                                .disabled(selected.automaticLanguage != nil || loading || available.allSatisfy { resource in selected.members.contains { $0.id == resource.id } })
                            Button(L("Quitar del grupo"), systemImage: "trash") {
                                if let member = selectedMemberID { perform { try sets.removeMember(member, from: selected.id); selectedMemberID = nil } }
                            }.labelStyle(.iconOnly).help(L("Quitar del grupo")).disabled(selectedMemberID == nil || selected.automaticLanguage != nil)
                            Spacer()
                            Button(L("Subir"), systemImage: "chevron.up") { move(-1) }.labelStyle(.iconOnly).help(L("Subir")).disabled(!canMove(-1))
                            Button(L("Bajar"), systemImage: "chevron.down") { move(1) }.labelStyle(.iconOnly).help(L("Bajar")).disabled(!canMove(1))
                        }.controlSize(.small)
                    } else {
                        Text(L("Crea un grupo para elegir sus Biblias.")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(.leading, 10).frame(minWidth: 350)
            }.padding(.trailing, 20)
            if !sets.excludedAutomaticLanguages.isEmpty {
                Button(L("Restaurar grupos por idioma")) { perform { try sets.restoreAutomaticLanguages() } }.padding(.horizontal, 20)
            }
            if loading { ProgressView(L("Leyendo las Biblias disponibles…")).controlSize(.small).padding(.horizontal, 20) }
            if let error = error ?? sets.loadError {
                HStack {
                    Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button(L("Volver a cargar")) { perform { try sets.reload() } }
                }.padding(.horizontal, 20)
            }
        }.padding(.vertical, 20).featureHelpTarget(.groups)
        .onAppear { selectedSetID = selectedSetID ?? workspace.bibleGroups.first?.id; name = selected?.name ?? "" }
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
    private func removeGroup(_ id: UUID) {
        perform {
            if let language = workspace.bibleGroups.first(where: { $0.id == id })?.automaticLanguage {
                try sets.excludeAutomaticLanguage(language)
            } else { try sets.remove(id) }
            for reader in workspace.readers where reader.parallelSetID == id { reader.parallelSetID = nil }
            if selectedSetID == id { selectedSetID = workspace.bibleGroups.first?.id }
        }
    }
    private func canMove(_ delta: Int) -> Bool {
        guard let selected, selected.automaticLanguage == nil, let index = selected.members.firstIndex(where: { $0.id == selectedMemberID }) else { return false }
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
