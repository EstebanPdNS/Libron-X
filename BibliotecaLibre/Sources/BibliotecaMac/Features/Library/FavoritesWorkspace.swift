import AppKit
import LibronixCore
import SwiftUI

struct FavoritesWorkspace: View {
    @Bindable var model: LibraryModel
    @ViewState private var selection: UUID?
    @ViewState private var title = ""
    private var personal: PersonalLibraryStore { model.store.personal }
    private var selected: LibraryFavorite? { personal.favorites.items.first { $0.id == selection } }
    private var parent: UUID? { selected?.kind == .folder ? selection : selected?.parentID }
    private var flattened: [(LibraryFavorite, Int)] {
        func rows(_ parent: UUID?, depth: Int) -> [(LibraryFavorite, Int)] {
            personal.favorites.children(of: parent).flatMap { item in
                [(item, depth)] + (item.kind == .folder ? rows(item.id, depth: depth + 1) : [])
            }
        }
        return rows(nil, depth: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Favoritos y marcadores").font(.system(size: 28, design: .serif))
            HStack {
                Button("Nueva carpeta", systemImage: "folder.badge.plus") {
                    let item = LibraryFavorite(parentID: parent, title: "Nueva carpeta", kind: .folder)
                    personal.change { try $0.insert(item) }; selection = item.id
                }
                Button("Guardar lectura", systemImage: "star.badge.plus") {
                    guard let location = model.reader.currentLocation else { return }
                    let item = LibraryFavorite(parentID: parent, title: model.reader.currentTitle, kind: .location, location: location)
                    personal.change { try $0.insert(item) }; selection = item.id
                }.disabled(model.reader.currentLocation == nil)
                Menu("Más") {
                    Button("Importar favoritos de Libronix…", action: personal.importFavorites)
                    Divider()
                    Button("Deshacer", action: personal.undo).disabled(!personal.canUndo)
                    Button("Rehacer", action: personal.redo).disabled(!personal.canRedo)
                }
            }.controlSize(.small)
            if personal.favorites.items.isEmpty {
                ContentUnavailableView("Tus lugares de estudio", systemImage: "star",
                    description: Text("Guarda una lectura o crea carpetas para organizar tus favoritos."))
            } else {
                List(selection: $selection) {
                    ForEach(flattened, id: \.0.id) { item, depth in
                        HStack {
                            Label(item.title, systemImage: item.kind == .folder ? "folder" : "star")
                                .padding(.leading, CGFloat(min(depth, 8)) * 14)
                            Spacer()
                            if item.kind != .folder {
                                Button("Abrir") { model.navigateFavorite(item) }.buttonStyle(.borderless)
                                    .disabled(model.isResolvingOriginalDestination)
                            }
                        }.tag(item.id)
                    }
                }.listStyle(.inset)
            }
            if let selected {
                HStack {
                    TextField("Nombre del favorito", text: $title).textFieldStyle(.roundedBorder)
                        .onSubmit { personal.change { try $0.rename(selected.id, title: title) } }
                    Button("Renombrar") { personal.change { try $0.rename(selected.id, title: title) } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Menu("Mover a…") {
                        Button("Nivel principal") { personal.change { try $0.move(selected.id, into: nil) } }
                        ForEach(personal.favorites.items.filter { $0.kind == .folder && $0.id != selected.id }) { folder in
                            Button(folder.title) { personal.change { try $0.move(selected.id, into: folder.id) } }
                        }
                    }
                    Button("Eliminar", role: .destructive) { personal.change { $0.remove(selected.id) }; selection = nil }
                }.controlSize(.small)
                if selected.kind == .legacyCommand {
                    Text("Destino importado conservado. Abrir comprueba su edición y sus coordenadas antes de recuperar la lectura.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.isResolvingOriginalDestination { ProgressView("Recuperando el destino…").controlSize(.small) }
            Divider()
            Text("Marcadores numerados").font(.headline)
            ForEach(1...9, id: \.self) { slot in
                HStack {
                    Text("\(slot)").monospacedDigit().frame(width: 20)
                    Text(personal.bookmarks.slots[slot]?.reference ?? personal.bookmarks.slots[slot].map { "Artículo \($0.sectionOrdinal + 1)" } ?? "Sin asignar")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ir") { if let location = personal.bookmarks.slots[slot] { model.navigate(location) } }
                        .disabled(personal.bookmarks.slots[slot] == nil)
                    Button("Asignar") { personal.setBookmark(slot, location: model.reader.currentLocation) }
                        .disabled(model.reader.currentLocation == nil)
                    Button("Borrar") { personal.setBookmark(slot, location: nil) }.disabled(personal.bookmarks.slots[slot] == nil)
                }.controlSize(.small)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: selection) { _, _ in title = selected?.title ?? "" }
        .alert("No se pudo guardar el cambio", isPresented: Binding(get: { personal.errorMessage != nil }, set: { if !$0 { personal.errorMessage = nil } })) {
            Button("Aceptar", role: .cancel) { personal.errorMessage = nil }
        } message: { Text(personal.errorMessage ?? "") }
    }
}

struct LibraryWindowAttachment: NSViewRepresentable {
    let attach: (NSWindow) -> Void
    final class Probe: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { attach?(window) } }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.attach = attach; return view }
    func updateNSView(_ view: Probe, context: Context) { view.attach = attach }
}
