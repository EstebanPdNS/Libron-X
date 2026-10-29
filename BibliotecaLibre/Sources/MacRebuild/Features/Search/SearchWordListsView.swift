import SwiftUI
import LibronixCore

struct WorkspaceWordFiltersView: View {
    @Bindable var search: WorkspaceSearchController
    @Bindable var personal: WorkspacePersonalState
    @RebuildViewState private var managing = false
    private func selection(_ include: Bool) -> Binding<String> {
        Binding(get: {
            let terms = include ? (search.wordFilter?.include ?? []) : (search.wordFilter?.exclude ?? [])
            guard !terms.isEmpty else { return "" }
            return personal.searchWordLists.lists.first(where: { $0.terms == terms })?.id.uuidString ?? "snapshot"
        }, set: { choice in
            if choice == "snapshot" { return }
            let terms = personal.searchWordLists.lists.first(where: { $0.id.uuidString == choice })?.terms ?? []
            var filter = search.wordFilter ?? SearchWordFilter()
            if include { filter.include = terms } else { filter.exclude = terms }
            search.wordFilter = filter.include.isEmpty && filter.exclude.isEmpty ? nil : filter
        })
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Incluir palabras")).font(.caption).foregroundStyle(.secondary)
                MacSelectionMenu(L("Incluir palabras"), value: selectedTitle(true), selection: selection(true), fillsWidth: true) { options(include: true) }
                Text(L("Excluir palabras")).font(.caption).foregroundStyle(.secondary)
                MacSelectionMenu(L("Excluir palabras"), value: selectedTitle(false), selection: selection(false), fillsWidth: true) { options(include: false) }
                Button(L("Listas de palabras…")) { managing = true }
                Text(L("Incluye cualquiera de la primera lista y excluye cualquiera de la segunda."))
                    .font(.caption).foregroundStyle(.secondary)
                if search.approximatePhrase && search.wordFilter != nil {
                    Text(L("Las listas de palabras requieren coincidencia exacta.")).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(search.isSearching)
        } label: {
            Text(L(search.wordFilter == nil ? "Listas de palabras" : "Listas de palabras activas"))
        }.sheet(isPresented: $managing) { SearchWordListsManager(personal: personal).modifier(AppInterfaceLanguage()) }
    }
    private func selectedTitle(_ include: Bool) -> String {
        let choice = selection(include).wrappedValue
        return personal.searchWordLists.lists.first { $0.id.uuidString == choice }?.name ?? L(choice == "snapshot" ? "Filtro restaurado" : "Sin filtro")
    }
    @ViewBuilder private func options(include: Bool) -> some View {
        Text(L("Sin filtro")).tag("")
        let terms = include ? (search.wordFilter?.include ?? []) : (search.wordFilter?.exclude ?? [])
        if !terms.isEmpty && !personal.searchWordLists.lists.contains(where: { $0.terms == terms }) {
            Text(L("Filtro restaurado")).tag("snapshot")
        }
        ForEach(personal.searchWordLists.lists) { Text($0.name).tag($0.id.uuidString) }
    }
}
private struct SearchWordListsManager: View {
    @Bindable var personal: WorkspacePersonalState
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var name = ""
    @RebuildViewState private var terms = ""
    @RebuildViewState private var deleting = false
    @RebuildViewState private var error: String?
    private var selected: SearchWordList? { personal.searchWordLists.lists.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Listas de palabras") { dismiss() }
            List(personal.searchWordLists.lists, selection: $selectedID) { list in Text(list.name).tag(list.id) }
                .overlay { if personal.searchWordLists.lists.isEmpty { Text(L("No hay listas de palabras.")).foregroundStyle(.secondary).allowsHitTesting(false) } }
            TextField(L("Nombre de lista"), text: $name).macInputStyle()
            Text(L("Una palabra o frase por línea"))
            TextEditor(text: $terms).scrollContentBackground(.hidden).padding(8).frame(minHeight: 100, maxHeight: 140)
                .macEditorSurface()
                .accessibilityLabel(L("Una palabra o frase por línea"))
            if let message = error ?? personal.searchWordListsLoadError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L("Añadir lista")) { save(add: true) }
                Button(L("Actualizar lista")) { save(add: false) }.disabled(selected == nil)
                Button(L("Eliminar lista")) { deleting = true }.disabled(selected == nil)
                Spacer()
            }
        }.padding(16).frame(width: 600, height: 550).modifier(MacPanelControlPresentation())
            .onChange(of: selectedID) { name = selected?.name ?? ""; terms = selected?.terms.joined(separator: "\n") ?? "" }
            .alert(L("Eliminar lista"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { remove() }
            } message: { Text(L("Se eliminará esta lista de palabras.")) }
    }
    private func save(add: Bool) {
        let original = add ? nil : selected
        if !add && original == nil { return }
        let entries = terms.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var list = original ?? SearchWordList(name: name, terms: entries)
        list.name = name.trimmingCharacters(in: .whitespacesAndNewlines); list.terms = entries
        do {
            try personal.editSearchWordLists { state in
                if let original {
                    guard let index = state.lists.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                    state.lists[index] = list
                } else { state.lists.append(list) }
            }
            selectedID = list.id; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func remove() {
        guard let original = selected else { return }
        do {
            try personal.editSearchWordLists { state in
                guard let index = state.lists.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                state.lists.remove(at: index)
            }
            selectedID = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
