import SwiftUI
import LibronixCore
import UniformTypeIdentifiers

private struct FavoriteNode: Identifiable {
    let favorite: LibraryFavorite
    let children: [FavoriteNode]?
    var id: UUID { favorite.id }
    static func tree(_ document: FavoritesDocument) -> [FavoriteNode] {
        let groups = Dictionary(grouping: document.items, by: \.parentID)
        func build(_ parent: UUID?) -> [FavoriteNode] {
            (groups[parent] ?? []).map { item in
                FavoriteNode(favorite: item, children: item.kind == .folder ? build(item.id) : nil)
            }
        }
        return build(nil)
    }
}
private struct FavoriteRows: View {
    let nodes: [FavoriteNode]
    @Binding var expanded: Set<UUID>
    @Bindable var workspace: StudyWorkspace
    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(node.id) }, set: { value in
                    if value { expanded.insert(node.id) } else { expanded.remove(node.id) }
                })) {
                    FavoriteRows(nodes: children, expanded: $expanded, workspace: workspace)
                } label: { row(node) }.tag(node.id)
            } else { row(node).tag(node.id) }
        }
    }
    private func row(_ node: FavoriteNode) -> some View {
        HStack {
            Image(systemName: node.favorite.kind == .folder ? "folder" : node.favorite.kind == .location ? "bookmark" : "doc.text")
                .foregroundStyle(.secondary)
            Text(node.favorite.title).lineLimit(1)
            Spacer()
            if node.favorite.kind == .location || node.favorite.kind == .legacyCommand {
                Button(L("Abrir")) { workspace.openFavorite(node.favorite) }
            }
        }
    }
}
private struct FavoriteMoveRequest: Identifiable { let id: UUID }

struct WorkspaceFavoritesView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var selected: UUID?
    @RebuildViewState private var expanded: Set<UUID> = []
    @RebuildViewState private var draft = ""
    @RebuildViewState private var creating = false
    @RebuildViewState private var renaming = false
    @RebuildViewState private var deleting = false
    @RebuildViewState private var importing = false
    @RebuildViewState private var moveRequest: FavoriteMoveRequest?
    private var favorites: FavoritesDocument { workspace.personal.favorites }
    private var item: LibraryFavorite? { favorites.items.first { $0.id == selected } }
    private var parentForNewFolder: UUID? { item?.kind == .folder ? item?.id : item?.parentID }
    private func canMove(_ delta: Int) -> Bool {
        guard let item else { return false }
        let siblings = favorites.children(of: item.parentID)
        guard let index = siblings.firstIndex(where: { $0.id == item.id }) else { return false }
        return siblings.indices.contains(index + delta)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(L("Agregar ubicación actual"), action: workspace.addFavorite).disabled(workspace.currentBookmarkLocation == nil)
            List(selection: $selected) {
                FavoriteRows(nodes: FavoriteNode.tree(favorites), expanded: $expanded, workspace: workspace)
            }
            .overlay {
                if favorites.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "star").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(L("Todavía no hay favoritos")).font(.headline)
                        Text(L("Añade una ubicación o importa tus favoritos originales desde Acciones."))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24).allowsHitTesting(false)
                }
            }
            MacReaderToolbarSurface {
                HStack {
                    MacReaderControlGroup {
                        MacToolbarButton("Nueva carpeta", "folder.badge.plus") { draft = ""; creating = true }
                        Menu {
                            Button(L("Importar favoritos originales…")) { importing = true }
                            Divider()
                            Button(L("Renombrar favorito")) { draft = item?.title ?? ""; renaming = true }.disabled(item == nil)
                            Button(L("Mover favorito…")) { if let selected { moveRequest = .init(id: selected) } }.disabled(item == nil)
                            Divider()
                            Button(L("Borrar favorito"), role: .destructive) { deleting = true }.disabled(item == nil)
                        } label: { Text(L("Acciones")).font(.callout) }
                    }
                    Spacer(minLength: 12)
                    MacReaderControlGroup {
                        MacToolbarButton("Subir", "chevron.up") { reorder(-1) }.disabled(!canMove(-1))
                        MacToolbarButton("Bajar", "chevron.down") { reorder(1) }.disabled(!canMove(1))
                    }
                }
            }
        }.padding(16)
            .alert(L("Nueva carpeta"), isPresented: $creating) {
                TextField(L("Nombre de la carpeta"), text: $draft)
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Guardar")) {
                    do {
                        let folder = LibraryFavorite(parentID: parentForNewFolder, title: draft.trimmingCharacters(in: .whitespacesAndNewlines), kind: .folder)
                        try workspace.personal.editFavorites { try $0.insert(folder) }
                        if let parent = folder.parentID { expanded.insert(parent) }
                        selected = folder.id
                    } catch { workspace.error = error.localizedDescription }
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(L("Renombrar favorito"), isPresented: $renaming) {
                TextField(L("Título"), text: $draft)
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Guardar")) {
                    guard let selected else { return }
                    do { try workspace.personal.editFavorites { try $0.rename(selected, title: draft.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                    catch { workspace.error = error.localizedDescription }
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(L("Borrar favorito"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Borrar"), role: .destructive) {
                    guard let selected else { return }
                    do { try workspace.personal.editFavorites { $0.remove(selected) }; self.selected = nil }
                    catch { workspace.error = error.localizedDescription }
                }
            } message: { Text(L("Si es una carpeta, también se borrarán sus contenidos.")) }
            .sheet(item: $moveRequest, onDismiss: expandSelectedAncestors) { request in
                FavoriteMoveView(personal: workspace.personal, id: request.id).modifier(AppInterfaceLanguage())
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    try workspace.personal.importOriginalFavorites(from: url)
                } catch { workspace.error = error.localizedDescription }
            }
    }
    private func expandSelectedAncestors() {
        let byID = Dictionary(uniqueKeysWithValues: favorites.items.map { ($0.id, $0) })
        var parent = selected.flatMap { byID[$0]?.parentID }
        while let id = parent, let item = byID[id] { expanded.insert(id); parent = item.parentID }
    }
    private func reorder(_ delta: Int) {
        guard let selected else { return }
        do { try workspace.personal.editFavorites { try $0.reorder(selected, by: delta) } }
        catch { workspace.error = error.localizedDescription }
    }
}

private struct FavoriteMoveView: View {
    let personal: WorkspacePersonalState
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var parentID: UUID?
    @RebuildViewState private var error: String?
    private var available: [LibraryFavorite] {
        let groups = Dictionary(grouping: personal.favorites.items, by: \.parentID)
        var excluded: Set<UUID> = [id], pending = [id]
        while let parent = pending.popLast() {
            for child in groups[parent] ?? [] where excluded.insert(child.id).inserted { pending.append(child.id) }
        }
        return personal.favorites.items.filter { $0.kind == .folder && !excluded.contains($0.id) }
    }
    private func path(_ folder: LibraryFavorite) -> String {
        let items = Dictionary(uniqueKeysWithValues: personal.favorites.items.map { ($0.id, $0) })
        var names = [folder.title], cursor = folder.parentID
        while let id = cursor, let parent = items[id], names.count < 128 {
            names.append(parent.title); cursor = parent.parentID
        }
        return names.reversed().joined(separator: " / ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacToolHeader(title: "Mover favorito") { dismiss() }
            Picker(L("Carpeta de destino"), selection: $parentID) {
                Text(L("Nivel principal")).tag(Optional<UUID>.none)
                ForEach(available) { Text(path($0)).tag(Optional($0.id)) }
            }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Cancelar")) { dismiss() }; Button(L("Mover")) {
                do { try personal.editFavorites { try $0.move(id, into: parentID) }; dismiss() }
                catch { self.error = error.localizedDescription }
            } }
        }.padding(20).frame(width: 500).modifier(MacPanelControlPresentation())
            .onAppear { parentID = personal.favorites.items.first(where: { $0.id == id })?.parentID }
    }
}
