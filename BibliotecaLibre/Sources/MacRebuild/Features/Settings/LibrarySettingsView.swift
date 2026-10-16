import SwiftUI
import LibronixCore

struct LibrarySettingsView: View {
    let workspace: StudyWorkspace
    @RebuildViewState private var query = ""
    @RebuildViewState private var onlyHidden = false
    @RebuildViewState private var selection: Set<String> = []
    @RebuildViewState private var error: String?
    private struct Row: Identifiable {
        let id: String
        let title: String
        let format: String
        let hidden: Bool
        var fileName: String { URL(fileURLWithPath: id).lastPathComponent }
    }
    private var rows: [Row] {
        let visibility = workspace.resourceVisibility
        let source: [Row]
        if onlyHidden {
            source = visibility.hidden.map { Row(id: $0.id, title: $0.title, format: $0.format.displayName, hidden: true) }
        } else {
            let known = Set(workspace.resources.map(\.id))
            source = workspace.resources.map { Row(id: $0.id, title: $0.title, format: $0.format.displayName, hidden: visibility.isHidden($0)) }
                + visibility.hidden.filter { !known.contains($0.id) }.map { Row(id: $0.id, title: $0.title, format: $0.format.displayName, hidden: true) }
        }
        return source.filter { query.isEmpty || ($0.title + " " + $0.fileName).localizedStandardContains(query) }
            .sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Recursos de la biblioteca")).font(.headline)
            Text(L("Los recursos ocultos no aparecen en Mi biblioteca ni en nuevas búsquedas, el explorador temático o Copiar versículos. Sus archivos se conservan. Las lecturas abiertas y tus documentos siguen disponibles."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(L("Buscar título o archivo"), text: $query).macInputStyle()
                Toggle(L("Solo ocultos"), isOn: $onlyHidden)
            }
            Table(rows, selection: $selection) {
                TableColumn(L("Recurso")) { row in
                    VStack(alignment: .leading) {
                        Text(row.title).lineLimit(1)
                        Text(row.fileName).font(.caption).foregroundStyle(.secondary)
                    }.help(row.id)
                }
                TableColumn(L("Formato"), value: \.format).width(90)
                TableColumn(L("Estado")) { row in Text(L(row.hidden ? "Oculto" : "Disponible")) }.width(min: 80, ideal: 110)
            }
            HStack {
                Text(LF("{count} ocultos", ["count": String(workspace.resourceVisibility.hidden.count)]))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Ocultar seleccionados")) {
                    perform { try workspace.hideLibraryResources(selectedVisible) }
                }.disabled(selectedVisible.isEmpty)
                Button(L("Volver a mostrar")) {
                    perform { try workspace.restoreLibraryResources(selectedHidden) }
                }.disabled(selectedHidden.isEmpty)
            }
            if let message = error ?? workspace.resourceVisibility.loadError {
                Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
        }.padding(20)
    }
    private var selectedVisible: Set<String> {
        Set(rows.filter { selection.contains($0.id) && !$0.hidden }.map(\.id))
    }
    private var selectedHidden: Set<String> {
        Set(rows.filter { selection.contains($0.id) && $0.hidden }.map(\.id))
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil; selection = [] }
        catch { self.error = error.localizedDescription }
    }
}
