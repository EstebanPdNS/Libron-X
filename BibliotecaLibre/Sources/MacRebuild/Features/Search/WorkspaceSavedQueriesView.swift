import SwiftUI

struct WorkspaceSavedQueriesView: View {
    @Bindable var store: WorkspaceSavedQueries
    @Bindable var search: WorkspaceSearchController
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var title = ""
    @RebuildViewState private var error: String?
    private var selected: WorkspaceSavedQuery? { store.queries.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            MacToolHeader(title: "Consultas guardadas") { dismiss() }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Selecciona una búsqueda para restaurar sus opciones. Después pulsa Buscar para ejecutarla."))
                    .font(.caption).foregroundStyle(.secondary)
                List(store.queries, selection: $selectedID) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).lineLimit(1)
                        Text(item.configuration.query).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.tag(item.id)
                }.overlay {
                    if store.queries.isEmpty { Text(L("No hay consultas guardadas.")).foregroundStyle(.secondary).allowsHitTesting(false) }
                }
                TextField(L("Nombre de la consulta"), text: $title).macInputStyle()
                HStack {
                    Button(L("Guardar consulta actual")) { save(asNew: true) }
                    Button(L("Actualizar consulta seleccionada")) { save(asNew: false) }.disabled(selected == nil)
                    Spacer()
                }
                if let message = error ?? store.loadError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button(L("Eliminar")) {
                        guard let selected else { return }
                        do { try store.remove(selected); selectedID = nil; title = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(selected == nil)
                    Spacer()
                    Button(L("Cancelar")) { dismiss() }
                    Button(L("Restaurar búsqueda")) {
                        guard let selected else { return }
                        do { try search.restore(selected.configuration); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(selected == nil || search.isSearching)
                }
            }.padding(16)
        }.frame(minWidth: 600, minHeight: 500)
            .modifier(MacPanelControlPresentation())
            .onChange(of: selectedID) { title = selected?.title ?? "" }
    }
    private func save(asNew: Bool) {
        let original = asNew ? nil : selected
        if !asNew && original == nil { return }
        var query = original ?? WorkspaceSavedQuery(title: title, configuration: search.historyConfiguration)
        query.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        query.configuration = search.historyConfiguration
        do { try store.save(original: original, replacement: query); selectedID = query.id; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
