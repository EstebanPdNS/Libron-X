import SwiftUI

struct WorkspaceSearchHistoryView: View {
    @Bindable var history: WorkspaceSearchHistory
    @Bindable var search: WorkspaceSearchController
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            MacToolHeader(title: "Historial de búsquedas") { dismiss() }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Selecciona una búsqueda para restaurar sus opciones. Después pulsa Buscar para ejecutarla."))
                    .font(.caption).foregroundStyle(.secondary)
                List(history.entries, selection: $selectedID) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.configuration.query).lineLimit(2)
                        Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.tag(entry.id)
                }.overlay {
                    if history.entries.isEmpty { Text(L("No hay búsquedas guardadas.")).foregroundStyle(.secondary).allowsHitTesting(false) }
                }
                if let message = error ?? history.loadError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button(L("Eliminar")) {
                        guard let selectedID else { return }
                        do { try history.remove(selectedID); self.selectedID = nil; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(selectedID == nil)
                    Spacer()
                    Button(L("Cancelar")) { dismiss() }
                    Button(L("Restaurar búsqueda")) {
                        guard let entry = history.entries.first(where: { $0.id == selectedID }) else { return }
                        do { try search.restore(entry.configuration); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(selectedID == nil || search.isSearching)
                }
            }.padding(16)
        }.frame(minWidth: 560, minHeight: 420)
         .modifier(MacPanelControlPresentation())
    }
}
