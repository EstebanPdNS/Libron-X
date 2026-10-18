import LibronixCore
import SwiftUI

struct LibraryChooser: View {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Bindable private var preferences = LibraryPreferences.shared
    @RebuildViewState private var showsCollections = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    libraryHeading
                    Spacer(minLength: 20)
                    libraryActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    libraryHeading
                    libraryActions
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Buscar título, autor, idioma o archivo"), text: $workspace.libraryQuery)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityIdentifier("library.search")
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(
                    searchFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: searchFocused ? 2 : 1)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    sortAndGroup
                    Divider().frame(height: 22)
                    metadataFilters
                }
                VStack(alignment: .leading, spacing: 10) {
                    sortAndGroup
                    metadataFilters
                }
            }
            GeometryReader { geometry in
            libraryTable(availableWidth: geometry.size.width)
            .controlSize(.regular)
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1) }
            .contextMenu(forSelectionType: String.self) { ids in
                Button(L("Abrir recurso")) { open(ids.first) }.disabled(ids.isEmpty)
                Button(L("Ocultar recurso")) {
                    do { try workspace.hideLibraryResources(ids) }
                    catch { workspace.error = error.localizedDescription }
                }.disabled(ids.isEmpty)
            } primaryAction: { ids in open(ids.first) }
            }
            if let resource = workspace.filteredResources.first(where: { $0.id == workspace.librarySelection }) {
                DisclosureGroup(L("Metadatos")) {
                    ScrollView {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                            ForEach(LibraryField.allCases) { field in
                                GridRow { Text(L(field.title)).foregroundStyle(.secondary); Text(field.value(resource)).textSelection(.enabled) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                }
            }
            HStack {
                Toggle(L("Mantener abierta"), isOn: $workspace.keepLibraryOpen)
                    .toggleStyle(.checkbox)
                columnsMenu
                Spacer()
                Text(LF("{count} recursos", ["count": String(workspace.filteredResources.count)]))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Abrir recurso")) { open(workspace.librarySelection) }
                    .disabled(!workspace.filteredResources.contains { $0.id == workspace.librarySelection }).keyboardShortcut(.defaultAction)
                Button(L("Cerrar")) { dismissWindow(id: "library") }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).font(.system(size: 13)).controlSize(.regular)
            .modifier(MacPanelControlPresentation()).featureHelpTarget(.library)
            .onAppear { searchFocused = true }
            .sheet(isPresented: $showsCollections) { LibraryCollectionsView(workspace: workspace) }
    }
    private var libraryHeading: some View {
        HStack(spacing: 10) {
            Text(L("Mi biblioteca")).font(.system(size: 22, weight: .bold)).fixedSize()
            HelpButton(topic: .library)
        }
    }
    private var libraryActions: some View {
        HStack(spacing: 10) {
            Button { showsCollections = true } label: { Label(L("Colecciones"), systemImage: "folder") }
            ResourceDirectoryButton(workspace: workspace)
            Button(action: workspace.chooseLibrary) { Label(L("Agregar carpeta"), systemImage: "plus.circle") }
            Button { workspace.chooseResources() } label: { Label(L("Importar recursos"), systemImage: "square.and.arrow.down") }
        }.fixedSize().controlSize(.regular)
    }
    private var sortAndGroup: some View {
        HStack(spacing: 8) {
            Text(L("Ordenar por")).fixedSize()
            Picker(L("Ordenar por"), selection: $workspace.librarySortField) {
                ForEach(LibraryField.allCases) { field in Text(L(field.title)).tag(field) }
            }.labelsHidden().frame(width: 110)
                .onChange(of: workspace.librarySortField) { _, _ in workspace.librarySortByAuthor = false }
            Text(L("Grupo")).fixedSize().padding(.leading, 6)
            Picker(L("Grupo"), selection: $workspace.libraryGroup) {
                Text(L("Todos los recursos")).tag("all")
                Text(L("Grupo de diccionarios")).tag("dictionaries")
                ForEach(workspace.libraryLanguages, id: \.self) { code in Text(LibraryLanguages.name(code)).tag("language:" + code) }
                ForEach(workspace.collections.sets) { collection in
                    Text(collection.name).tag("collection:" + collection.id.uuidString)
                }
                ForEach(workspace.parallelBibleSets.sets) { group in Text(group.name).tag("personal:" + group.id.uuidString) }
            }.labelsHidden().frame(width: 155)
        }.controlSize(.regular)
    }
    private var metadataFilters: some View {
        HStack(spacing: 8) {
            Text(L("Filtrar por")).fixedSize()
            Picker(L("Filtrar por"), selection: $workspace.libraryFacet) {
                ForEach([LibraryField.category, .type, .origin, .language, .year, .publisher]) { field in Text(L(field.title)).tag(field) }
            }.labelsHidden().frame(width: 120)
                .onChange(of: workspace.libraryFacet) { _, _ in workspace.libraryFacetValue = "" }
            Picker(L("Valor"), selection: $workspace.libraryFacetValue) {
                Text(L("Todos")).tag("")
                ForEach(Array(Set(workspace.availableResources.map { workspace.libraryFacet.value($0) })).filter { !$0.isEmpty }.sorted(), id: \.self) { value in Text(value).tag(value) }
            }.labelsHidden().frame(width: 145)
        }.controlSize(.regular)
    }
    private var columnsMenu: some View {
        Menu {
            ForEach(LibraryField.allCases.filter { $0 != .title }) { field in
                Toggle(L(field.title), isOn: Binding(get: { preferences.columns.contains(field) }, set: { _ in preferences.toggleColumn(field) }))
            }
        } label: { Label(L("Columnas"), systemImage: "slider.horizontal.3") }
            .fixedSize().controlSize(.regular)
    }
    private func columnWidth(_ field: LibraryField, availableWidth: CGFloat) -> (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) {
        let fields = [LibraryField.title] + preferences.columns.filter { $0 != .title }
        func weight(_ field: LibraryField) -> CGFloat {
            switch field {
            case .title: 2.7
            case .author: 1.3
            case .type: 1.4
            case .category: 1.6
            case .language, .origin: 0.9
            case .year, .originalYear: 0.8
            default: 1.4
            }
        }
        // Native table columns add their own cell padding outside these widths.
        let contentWidth = max(0, availableWidth - 20 - CGFloat(fields.count) * 17)
        let ideal = contentWidth * weight(field) / fields.reduce(0) { $0 + weight($1) }
        let minimum: CGFloat = switch field {
        case .title: 160
        case .author: 80
        case .type: 90
        case .category: 100
        case .language, .origin: 55
        case .year, .originalYear: 45
        default: 90
        }
        return (minimum, max(minimum, ideal), max(minimum, availableWidth))
    }
    @ViewBuilder private func libraryTable(availableWidth: CGFloat) -> some View {
        if #available(macOS 15.0, *) {
            Table(workspace.filteredResources, selection: $workspace.librarySelection) {
                TableColumn(L("Título"), value: \.title)
                    .width(min: columnWidth(.title, availableWidth: availableWidth).minimum,
                           ideal: columnWidth(.title, availableWidth: availableWidth).ideal,
                           max: columnWidth(.title, availableWidth: availableWidth).maximum)
                TableColumnForEach(preferences.columns.filter { $0 != .title }) { field in
                    TableColumn(L(field.title)) { (resource: LibraryResource) in
                        Text(field.value(resource)).lineLimit(1).truncationMode(.tail).help(field.value(resource))
                    }.width(min: columnWidth(field, availableWidth: availableWidth).minimum, ideal: columnWidth(field, availableWidth: availableWidth).ideal, max: columnWidth(field, availableWidth: availableWidth).maximum)
                }
            }
        } else {
            Table(workspace.filteredResources, selection: $workspace.librarySelection) {
                TableColumn(L("Título"), value: \.title)
                TableColumn(L("Autor")) { resource in Text(resource.author ?? "") }
                TableColumn(L("Idioma")) { resource in Text(LibraryField.language.value(resource)) }
                TableColumn(L("Tipo")) { resource in Text(LibraryField.type.value(resource)) }
                TableColumn(L("Origen")) { resource in Text(LibraryField.origin.value(resource)) }
            }
        }
    }
    private func open(_ id: String?) {
        guard let resource = workspace.filteredResources.first(where: { $0.id == id }) else { return }
        workspace.openSelectedLibraryResource(resource); openWindow(id: "study")
        if !workspace.keepLibraryOpen { dismissWindow(id: "library") }
    }
}

/// Uses the same directory and native presentation in both resource entry points.
struct ResourceDirectoryButton: View {
    let workspace: StudyWorkspace
    var body: some View {
        Button { workspace.openCurrentResourceDirectory() } label: {
            Label(L("Abrir directorio actual"), systemImage: "folder")
        }
        .help(workspace.currentResourceDirectory?.path ?? L("Abrir directorio actual"))
        .disabled(workspace.currentResourceDirectory == nil)
    }
}
