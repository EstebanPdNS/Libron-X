import SwiftUI
import LibronixCore

struct ResourceAssociationSettingsView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var selectedMemberID: String?
    @RebuildViewState private var selectedCandidateID: String?
    @RebuildViewState private var name = ""
    @RebuildViewState private var relation = AssociationRelation.alternatives
    @RebuildViewState private var kind = AssociationResourceKind.bible
    @RebuildViewState private var language = ""
    @RebuildViewState private var series = ""
    @RebuildViewState private var query = ""
    @RebuildViewState private var error: String?
    private var store: ResourceAssociationSets { workspace.resourceAssociations }
    private var selected: ResourceAssociationSet? { store.sets.first { $0.id == selectedID } }
    private var resources: [LibraryResource] { workspace.availableResources }
    private var draftScope: AssociationResourceScope {
        .init(kind: kind, language: LibraryLanguages.canonical(language.trimmingCharacters(in: .whitespacesAndNewlines)),
              series: kind == .series ? series.trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }
    private var edited: Bool {
        selected.map { name != $0.name || relation != $0.relation || draftScope != $0.scope } ?? false
    }
    private var candidates: [LibraryResource] {
        guard let selected else { return [] }
        let known = Set(selected.members.map(\.id))
        return resources.filter {
            !known.contains($0.id) && selected.scope.supports($0) &&
            (query.isEmpty || ($0.title + " " + $0.fileName).localizedStandardContains(query))
        }.sorted { a, b in
            let c = a.title.localizedStandardCompare(b.title)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                List(store.sets, selection: $selectedID) { value in
                    VStack(alignment: .leading) {
                        Text(value.name)
                        Text(L(value.relation.title) + " · " + L(value.scope.kind.title))
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(value.id)
                }.accessibilityLabel(L("Asociaciones de recursos"))
                Button(L("Nueva asociación"), systemImage: "plus") {
                    perform { selectedID = try store.create() }
                }.frame(maxWidth: .infinity)
            }.frame(minWidth: 170, idealWidth: 200, maxWidth: 240).padding(10)
            VStack(alignment: .leading, spacing: 10) {
                if let selected {
                    profile(selected)
                    Text(LF("{count} recursos", ["count": String(selected.members.count)]))
                        .font(.caption).foregroundStyle(.secondary)
                    List(selected.members, selection: $selectedMemberID) { member in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selected.resolve(member, in: resources)?.title ?? member.title).lineLimit(2)
                            Text(selected.resolve(member, in: resources)?.fileName ?? L("Recurso no disponible o incompatible"))
                                .font(.caption).foregroundStyle(selected.resolve(member, in: resources) == nil ? .orange : .secondary)
                        }.tag(member.id)
                    }.frame(minHeight: 100).accessibilityLabel(L("Orden de recursos asociados"))
                    HStack {
                        Button(L("Quitar del grupo"), systemImage: "minus") {
                            if let member = selectedMemberID { perform { try store.removeMember(member, from: selected.id); selectedMemberID = nil } }
                        }.disabled(selectedMemberID == nil)
                        Spacer()
                        Button(L("Subir"), systemImage: "chevron.up") { move(-1) }.disabled(!canMove(-1))
                        Button(L("Bajar"), systemImage: "chevron.down") { move(1) }.disabled(!canMove(1))
                    }.controlSize(.small)
                    candidatePicker(selected)
                    Text(L("Las asociaciones conservan su orden y los recursos ausentes. Los grupos de Biblias se administran por separado."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Crea una asociación para elegir recursos alternativos o complementarios."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let message = error ?? store.loadError {
                    Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                HStack {
                    Button(L("Volver a cargar")) { perform { try store.reload(); selectValidGroup(); loadDraft() } }
                    Spacer()
                    Button(L("Eliminar asociación"), systemImage: "trash", role: .destructive) {
                        if let id = selectedID { perform { try store.remove(id); selectValidGroup() } }
                    }.disabled(selected == nil)
                }.controlSize(.small)
            }.padding(14).frame(minWidth: 430)
        }
        .onAppear { selectValidGroup(); loadDraft() }
        .onChange(of: selectedID) { loadDraft(); selectedMemberID = nil; selectedCandidateID = nil; query = ""; error = nil }
    }
    @ViewBuilder private func profile(_ selected: ResourceAssociationSet) -> some View {
        TextField(L("Nombre de la asociación"), text: $name).macInputStyle().onSubmit(save)
        HStack {
            Picker(L("Relación"), selection: $relation) {
                ForEach(AssociationRelation.allCases) { Text(L($0.title)).tag($0) }
            }
            Picker(L("Tipo"), selection: $kind) {
                ForEach(AssociationResourceKind.allCases) { Text(L($0.title)).tag($0) }
            }
        }
        HStack {
            TextField(L("Código de idioma (opcional)"), text: $language).macInputStyle().onSubmit(save)
            if kind == .series {
                TextField(L("Nombre de la serie"), text: $series).macInputStyle().onSubmit(save)
            }
            Button(L("Guardar"), action: save).disabled(!edited)
        }
    }
    @ViewBuilder private func candidatePicker(_ selected: ResourceAssociationSet) -> some View {
        DisclosureGroup(L("Agregar recursos compatibles")) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(L("Filtrar recursos"), text: $query).macInputStyle()
                if candidates.isEmpty {
                    Text(L("No hay recursos compatibles para agregar.")).font(.caption).foregroundStyle(.secondary)
                }
                List(candidates, selection: $selectedCandidateID) { resource in
                    VStack(alignment: .leading) {
                        Text(resource.title).lineLimit(1)
                        Text(resource.fileName).font(.caption).foregroundStyle(.secondary)
                    }.tag(resource.id)
                }.frame(height: 120).accessibilityLabel(L("Recursos compatibles"))
                Button(L("Agregar recurso"), systemImage: "plus") {
                    guard let resource = candidates.first(where: { $0.id == selectedCandidateID }) else { return }
                    perform { try store.add([resource], to: selected.id); selectedMemberID = resource.id; selectedCandidateID = nil }
                }.disabled(edited || !candidates.contains { $0.id == selectedCandidateID })
                if edited { Text(L("Guarda los cambios antes de agregar recursos.")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func save() {
        guard let id = selectedID else { return }
        perform { try store.configure(id, name: name, relation: relation, scope: draftScope, resources: resources); loadDraft() }
    }
    private func loadDraft() {
        name = selected?.name ?? ""; relation = selected?.relation ?? .alternatives
        kind = selected?.scope.kind ?? .bible; language = selected?.scope.language ?? ""; series = selected?.scope.series ?? ""
    }
    private func selectValidGroup() {
        if !store.sets.contains(where: { $0.id == selectedID }) { selectedID = store.sets.first?.id }
        if let member = selectedMemberID, selected?.members.contains(where: { $0.id == member }) != true { selectedMemberID = nil }
    }
    private func canMove(_ delta: Int) -> Bool {
        guard let selected, let index = selected.members.firstIndex(where: { $0.id == selectedMemberID }) else { return false }
        return selected.members.indices.contains(index + delta)
    }
    private func move(_ delta: Int) {
        guard let selected, let member = selectedMemberID else { return }
        perform { try store.moveMember(member, in: selected.id, by: delta) }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
