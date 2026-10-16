import LibronixCore
import SwiftUI

struct LibraryChooser: View {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Mi biblioteca")).font(.title2)
                Spacer()
                Button(L("Abrir carpeta…"), action: workspace.chooseLibrary)
            }
            HStack {
                Text(L("Ordenar por:"))
                Picker(L("Ordenar por"), selection: $workspace.librarySortByAuthor) {
                    Text(L("Título")).tag(false); Text(L("Autor")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
            }
            TextField(L("Buscar título, autor o archivo"), text: $workspace.libraryQuery).macInputStyle()
            Table(workspace.filteredResources, selection: $workspace.librarySelection) {
                TableColumn(L("Título"), value: \.title)
                TableColumn(L("Autor")) { resource in Text(resource.author ?? "") }
                TableColumn(L("Formato")) { resource in Text(resource.format.displayName) }.width(100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button(L("Abrir recurso")) { open(ids.first) }.disabled(ids.isEmpty)
                Button(L("Ocultar recurso")) {
                    do { try workspace.hideLibraryResources(ids) }
                    catch { workspace.error = error.localizedDescription }
                }.disabled(ids.isEmpty)
            } primaryAction: { ids in open(ids.first) }
            HStack {
                Toggle(L("Mantener abierta"), isOn: $workspace.keepLibraryOpen)
                Spacer()
                Text(LF("{count} recursos", ["count": String(workspace.filteredResources.count)]))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Abrir recurso")) { open(workspace.librarySelection) }
                    .disabled(!workspace.filteredResources.contains { $0.id == workspace.librarySelection }).keyboardShortcut(.defaultAction)
                Button(L("Cerrar")) { dismissWindow(id: "library") }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).modifier(MacPanelControlPresentation())
    }
    private func open(_ id: String?) {
        guard let resource = workspace.filteredResources.first(where: { $0.id == id }) else { return }
        workspace.openSelectedLibraryResource(resource); openWindow(id: "study")
        if !workspace.keepLibraryOpen { dismissWindow(id: "library") }
    }
}
