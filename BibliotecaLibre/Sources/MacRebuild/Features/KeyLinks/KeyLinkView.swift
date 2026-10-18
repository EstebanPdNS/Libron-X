import SwiftUI
import LibronixCore

struct KeyLinkScopePicker: View {
    @Binding var scope: KeyLinkScope
    let workspace: StudyWorkspace
    private var languages: [String] {
        Array(Set(workspace.resources.flatMap { LibronMetadata.deriving($0).languages }.map(LibraryLanguages.canonical)
            + ["es", "en", "el", "he"] + (scope.language.isEmpty ? [] : [scope.language]))).sorted()
    }
    var body: some View {
        HStack {
            Picker(L("Tipo"), selection: $scope.kind) {
                ForEach(KeyLinkKind.allCases) { kind in Text(L(kind.title)).tag(kind) }
            }
            Picker(L("Idioma"), selection: $scope.language) {
                Text(L("Todos")).tag("")
                ForEach(languages, id: \.self) { Text(LibraryLanguages.name($0) + " · " + $0).tag($0) }
            }
        }
    }
}
struct KeyLinkView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var controller: KeyLinkController
    @RebuildViewState private var showsPriorities = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                KeyLinkScopePicker(scope: $controller.scope, workspace: workspace)
                Button(L("Prioridades")) { showsPriorities = true }
            }
            HStack {
                TextField(L("Referencia o entrada"), text: $controller.query).macInputStyle()
                    .onSubmit { controller.run(workspace: workspace) }
                Button(L("Buscar")) { controller.run(workspace: workspace) }.disabled(controller.query.isEmpty || controller.isLoading)
                Button(L("Abrir preferidos")) { controller.run(workspace: workspace, openPreferred: true) }
                    .disabled(controller.query.isEmpty || controller.isLoading)
                if controller.isLoading { Button(L("Cancelar")) { controller.cancel() } }
            }
            if controller.isLoading { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.results) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(result.resource.title).font(.headline)
                                    Text(result.label).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L("Abrir")) { workspace.openKeyLink(result) }
                            }
                            if !result.page.text.isEmpty {
                                DisclosureGroup(L("Vista previa")) { Text(result.excerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if controller.completed && controller.results.isEmpty { Text(L("Sin coincidencias")).foregroundStyle(.secondary) }
            Text(LF("{count} recursos", ["count": String(controller.examined)])).font(.caption).foregroundStyle(.secondary)
            if !controller.failures.isEmpty {
                DisclosureGroup(L("Advertencias")) {
                    ScrollView { Text(controller.failures.joined(separator: "\n")).textSelection(.enabled).font(.caption) }.frame(maxHeight: 100)
                }
            }
        }.padding(16)
            .onChange(of: controller.scope) { controller.clear() }
            .onChange(of: controller.query) { controller.clear() }
            .onDisappear { controller.cancel() }
            .sheet(isPresented: $showsPriorities) { ResourcePrioritiesView(workspace: workspace, initialScope: controller.scope) }
    }
}

struct ResourcePrioritiesView: View {
    @Bindable var workspace: StudyWorkspace
    let initialScope: KeyLinkScope
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var scope = KeyLinkScope(kind: .bible)
    @RebuildViewState private var selection: String?
    @RebuildViewState private var candidateID: String?
    @RebuildViewState private var query = ""
    @RebuildViewState private var error: String?
    private var store: ResourcePriorities { workspace.resourcePriorities }
    private var preference: KeyLinkPreference { store.preference(scope) }
    private var available: [LibraryResource] {
        workspace.availableResources.filter { scope.supports($0) && (query.isEmpty || ($0.title + " " + $0.fileName).localizedStandardContains(query)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Prioridades")).font(.title2.bold()); Spacer()
                Button(L("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            KeyLinkScopePicker(scope: $scope, workspace: workspace)
            HStack {
                Text(L("Ventanas"))
                Picker(L("Ventanas"), selection: Binding(get: { preference.openCount }, set: { count in perform { try store.setOpenCount(count, in: scope) } })) {
                    ForEach(1...8, id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().frame(width: 70)
                Spacer()
                Button(L("Restablecer prioridades")) { perform { try store.reset(scope); selection = nil } }
                    .disabled(!store.preferences.contains { $0.scope == scope })
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Recursos preferidos")).font(.headline)
                    List(preference.promoted, selection: $selection) { member in
                        VStack(alignment: .leading) {
                            Text(member.title).lineLimit(2)
                            if member.resolve(in: workspace.availableResources) == nil { Text(L("Recurso no disponible")).font(.caption).foregroundStyle(.secondary) }
                        }.tag(member.id)
                    }.accessibilityLabel(L("Recursos preferidos"))
                    HStack {
                        Button(L("Quitar prioridad"), systemImage: "minus.circle") {
                            if let selection { perform { try store.remove(selection, in: scope); self.selection = nil } }
                        }.labelStyle(.iconOnly).help(L("Quitar prioridad")).disabled(selection == nil)
                        Spacer()
                        Button(L("Subir"), systemImage: "chevron.up") { move(-1) }.labelStyle(.iconOnly).help(L("Subir")).disabled(!canMove(-1))
                        Button(L("Bajar"), systemImage: "chevron.down") { move(1) }.labelStyle(.iconOnly).help(L("Bajar")).disabled(!canMove(1))
                    }
                }.frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("Buscar título o archivo"), text: $query).macInputStyle()
                    Table(available, selection: $candidateID) {
                        TableColumn(L("Recurso")) { Text($0.title).lineLimit(2) }
                        TableColumn(L("Habilitado")) { resource in
                            Toggle(resource.title, isOn: Binding(get: { store.enabled(resource, in: scope) }, set: { value in
                                perform { try store.setEnabled(value, resources: [resource], in: scope) }
                            })).labelsHidden().toggleStyle(.checkbox)
                        }.width(75)
                    }.accessibilityLabel(L("Recursos de la biblioteca"))
                    HStack {
                        Button(L("Promover")) {
                            if let resource = available.first(where: { $0.id == candidateID }) { perform { try store.promote(resource, in: scope) } }
                        }.disabled(!available.contains { $0.id == candidateID && !preference.promoted.contains { $0.id == candidateID } })
                        Spacer(minLength: 4)
                        Button(L("Seleccionar todos")) { perform { try store.setEnabled(true, resources: available, in: scope) } }
                        Button(L("Desmarcar todos")) { perform { try store.setEnabled(false, resources: available, in: scope) } }
                    }
                }.padding(.leading, 12).frame(minWidth: 340)
            }
            if let message = error ?? store.loadError {
                HStack {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button(L("Volver a cargar")) { perform { try store.reload() } }
                }
            }
        }.padding(20).frame(width: 780, height: 600).modifier(MacPanelControlPresentation())
            .onAppear { scope = initialScope }.onChange(of: scope) { selection = nil; candidateID = nil }
    }
    private func canMove(_ delta: Int) -> Bool {
        guard let index = preference.promoted.firstIndex(where: { $0.id == selection }) else { return false }
        return preference.promoted.indices.contains(index + delta)
    }
    private func move(_ delta: Int) { if let selection { perform { try store.move(selection, in: scope, by: delta) } } }
    private func perform(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
}
