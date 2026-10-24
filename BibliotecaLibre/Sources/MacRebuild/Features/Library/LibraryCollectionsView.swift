import SwiftUI
import LibronixCore

/// Collection membership is independent of parallel-Bible navigation.
struct LibraryCollectionsView: View {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var memberID: String?
    @RebuildViewState private var candidates: Set<String> = []
    @RebuildViewState private var name = ""
    @RebuildViewState private var query = ""
    @RebuildViewState private var error: String?
    @RebuildViewState private var draftRule = LibraryCollectionRule()
    private var store: LibraryCollections { workspace.collections }
    private var selected: LibraryCollection? { store.sets.first { $0.id == selectedID } }
    private var available: [LibraryResource] {
        let included = Set(selected?.members.map(\.id) ?? [])
        return workspace.availableResources.filter {
            !included.contains($0.id) && (query.isEmpty || ($0.title + " " + $0.fileName).localizedStandardContains(query))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Colecciones") { dismiss() }
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    List(store.sets, selection: $selectedID) { collection in
                        VStack(alignment: .leading) {
                            Text(collection.name)
                            if collection.rule != nil { Text(L("Por reglas")).font(.caption).foregroundStyle(.secondary) }
                            Text(LF("{count} recursos", ["count": String(collection.resolvedMembers(in: workspace.availableResources).count)]))
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(collection.id)
                    }.accessibilityLabel(L("Colecciones"))
                    Button(L("Nueva colección"), systemImage: "plus.circle") {
                        perform { selectedID = try store.create() }
                    }
                    Button(L("Nueva colección por reglas"), systemImage: "line.3.horizontal.decrease.circle") {
                        perform {
                            selectedID = try store.create(rule: .init(conditions: [.init(operation: .exists)]))
                        }
                    }
                }.frame(minWidth: 170, idealWidth: 185, maxWidth: 220)
                VStack(alignment: .leading, spacing: 10) {
                    if let selected {
                        HStack {
                            TextField(L("Nombre de la colección"), text: $name).macInputStyle()
                                .onSubmit { rename(selected.id) }
                            Button(L("Guardar")) { rename(selected.id) }.disabled(name == selected.name)
                            Button(L("Eliminar colección"), systemImage: "trash", role: .destructive) {
                                perform {
                                    try store.remove(selected.id)
                                    if workspace.libraryGroup == "collection:" + selected.id.uuidString { workspace.libraryGroup = "all" }
                                    selectedID = store.sets.first?.id
                                }
                            }.labelStyle(.iconOnly).help(L("Eliminar colección"))
                        }
                        if let savedRule = selected.rule {
                            LibraryCollectionRuleEditor(rule: $draftRule, savedRule: savedRule,
                                resources: workspace.availableResources,
                                save: { perform { try store.saveRule(draftRule, for: selected.id) } })
                            Button(L("Mostrar en biblioteca")) {
                                workspace.libraryGroup = "collection:" + selected.id.uuidString
                                workspace.libraryQuery = ""; workspace.libraryFacetValue = ""; dismiss()
                            }.disabled(draftRule != savedRule)
                        } else {
                        List(selected.members, selection: $memberID) { member in
                            VStack(alignment: .leading) {
                                Text(member.title).lineLimit(1)
                                Text(member.resolve(in: workspace.availableResources)?.fileName ?? L("Recurso no disponible"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.tag(member.id)
                        }.accessibilityLabel(L("Recursos de la colección"))
                        HStack {
                            Button(L("Quitar de la colección"), systemImage: "minus.circle") {
                                guard let memberID else { return }
                                perform { try store.removeMember(memberID, from: selected.id); self.memberID = nil }
                            }.disabled(memberID == nil)
                            Spacer()
                            Button(L("Mostrar en biblioteca")) {
                                workspace.libraryGroup = "collection:" + selected.id.uuidString
                                workspace.libraryQuery = ""; workspace.libraryFacetValue = ""
                                dismiss()
                            }
                        }
                        Text(L("Recursos de la biblioteca")).font(.headline)
                        TextField(L("Buscar título o archivo"), text: $query).macInputStyle()
                        Table(available, selection: $candidates) {
                            TableColumn(L("Recurso")) { resource in
                                VStack(alignment: .leading) {
                                    Text(resource.title).lineLimit(1)
                                    Text(resource.fileName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            TableColumn(L("Formato")) { Text($0.format.displayName) }.width(75)
                        }.accessibilityLabel(L("Agregar recursos a la colección"))
                        Button(L("Agregar seleccionados"), systemImage: "plus.circle") {
                            perform {
                                try store.add(available.filter { candidates.contains($0.id) }, to: selected.id)
                                candidates = []
                            }
                        }.disabled(!available.contains { candidates.contains($0.id) })
                        }
                    } else {
                        Text(L("Crea una colección para elegir sus recursos.")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(.leading, 12).frame(minWidth: 450)
            }
            if let message = error ?? store.loadError {
                HStack {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button(L("Volver a cargar")) { perform { try store.reload() } }
                }
            }
        }.padding(20).frame(width: 780, height: 620).modifier(MacPanelControlPresentation())
            .onAppear { selectedID = store.sets.first?.id; name = selected?.name ?? ""; draftRule = selected?.rule ?? .init() }
            .onChange(of: selectedID) { name = selected?.name ?? ""; draftRule = selected?.rule ?? .init(); memberID = nil; candidates = [] }
    }
    private func rename(_ id: UUID) {
        perform { try store.rename(id, to: name); name = selected?.name ?? "" }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); error = nil } catch { self.error = error.localizedDescription }
    }
}
