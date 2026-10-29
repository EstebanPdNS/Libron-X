import SwiftUI
import LibronixCore

struct WorkspaceSearchScopePicker: View {
    @Bindable var selection: WorkspaceSearchScopeSelection
    let context: WorkspaceSearchScopeContext
    var stacked = false
    @RebuildViewState private var filter = ""
    private var choices: [LibraryResource] {
        context.choices().sorted { a, b in
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
    private var matches: [LibraryResource] {
        choices.filter { filter.isEmpty || ($0.title + " " + $0.location.lastPathComponent).localizedStandardContains(filter) }
    }
    private var subsetSelection: Binding<Set<String>> {
        Binding(get: { selection.selectedSubsetIDs }, set: { next in
            let visible = Set(matches.map(\.id))
            let retained = selection.selectedSubsetIDs.subtracting(visible)
            selection.selectSubset(next.union(retained), in: choices)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: stacked ? 6 : 8) {
            if stacked {
                Text(L("Ámbito")).font(.caption).foregroundStyle(.secondary)
                scopeMenu
                if selection.kind == .resource {
                    Text(L("Recurso")).font(.caption).foregroundStyle(.secondary)
                    resourceMenu
                }
            } else {
                HStack {
                    Text(L("Ámbito")); scopeMenu
                    if selection.kind == .resource { Text(L("Recurso")); resourceMenu }
                }
            }
            if selection.kind == .collections {
                List(context.collections, selection: $selection.collectionIDs) { collection in
                    Text(collection.name).tag(collection.id)
                }.frame(height: 100)
                Text(L("Selecciona una o varias colecciones con ⌘.")).font(.caption).foregroundStyle(.secondary)
            } else if selection.kind == .subset {
                TextField(L("Filtrar recursos de la selección"), text: $filter).macInputStyle()
                List(matches, selection: subsetSelection) { resource in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resource.title)
                        Text(resource.location.lastPathComponent + " · " + resource.format.displayName).font(.caption).foregroundStyle(.secondary)
                    }.tag(resource.id)
                }.frame(height: 110)
                HStack {
                    Text(LF("{count} recursos seleccionados", ["count": String(selection.selectedSubsetIDs.count)])).font(.caption)
                    Spacer()
                    Button(L("Limpiar selección"), action: selection.clearSubset).disabled(selection.selectedSubsetIDs.isEmpty)
                }
            } else if selection.kind == .openReaders {
                Text(L("Se buscan los recursos completos de los lectores abiertos, incluidos los minimizados."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var scopeMenu: some View {
        MacSelectionMenu(L("Ámbito"), value: selection.kind.title, selection: $selection.kind) {
            ForEach(WorkspaceSearchScopeKind.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }
    private var resourceMenu: some View {
        MacSelectionMenu(L("Recurso"), value: choices.first { $0.id == selection.resourceID }?.title ?? L("Selecciona un recurso"), selection: $selection.resourceID) {
            Text(L("Selecciona un recurso")).tag(Optional<String>.none)
            ForEach(choices) { Text($0.title).tag(Optional($0.id)) }
        }
    }
}
@MainActor extension WorkspaceSearchScopeSnapshot {
    var issueLines: [String] {
        var result = issues.prefix(100).map(\.description)
        if issues.count > 100 { result.append(LF("{count} avisos adicionales", ["count": String(issues.count - 100)])) }
        return result
    }
}
