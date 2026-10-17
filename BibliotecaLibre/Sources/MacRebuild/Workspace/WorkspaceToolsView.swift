import AppKit
import SwiftUI
import LibronixCore

struct WorkspaceToolsView: View {
    let tool: WorkspaceTool
    @Bindable var workspace: StudyWorkspace
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L(title)).font(.headline); Spacer()
                Button(L("Cerrar")) { workspace.activeTool = nil }.keyboardShortcut(.cancelAction)
            }.padding(14).background(.bar)
            Divider()
            switch tool {
            case .search: WorkspaceSearchView(workspace: workspace, search: workspace.search)
            case .documents: WorkspaceDocumentsView(workspace: workspace, personal: workspace.personal)
            case .favorites: WorkspaceFavoritesView(workspace: workspace)
            case .information: ResourceInformationView(reader: workspace.activeReader)
            case .resources: ResourceManagerView(workspace: workspace)
            case .topics: TopicBrowserView(workspace: workspace)
            case .bibleCopy: BibleCopyToolView(workspace: workspace)
            case .windows: WorkspaceWindowsView(workspace: workspace)
            case .parallelSets: ParallelBibleSettingsView(workspace: workspace)
            }
        }.frame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 620)
            .modifier(MacPanelControlPresentation())
    }
    private var title: String {
        switch tool {
        case .search: "Buscar"
        case .documents: "Documentos de estudio"
        case .favorites: "Favoritos"
        case .information: "Propiedades del recurso"
        case .resources: "Recursos y licencias"
        case .topics: "Explorador temático"
        case .bibleCopy: "Copiar versículos bíblicos"
        case .windows: "Ventanas"
        case .parallelSets: "Grupos de Biblias paralelas"
        }
    }
}

struct WorkspaceSearchView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var search: WorkspaceSearchController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("Palabra, frase entre comillas o consulta AND / OR"), text: $search.query).macInputStyle()
                    .onSubmit { search.run(workspace.availableResources) }
                if search.isSearching { Button(L("Cancelar"), action: search.cancel) }
                else { Button(L("Buscar")) { search.run(workspace.availableResources) }.disabled(search.query.isEmpty) }
            }
            HStack {
                Toggle(L("Toda la biblioteca"), isOn: $search.allResources)
                Picker(L("Recurso"), selection: Binding(get: { search.resourceID ?? "" }, set: { search.resourceID = $0 })) {
                    Text(L("Selecciona un recurso")).tag("")
                    ForEach(workspace.availableResources) { resource in Text(resource.title).tag(resource.id) }
                }.disabled(search.allResources)
            }.disabled(search.isSearching)
            HStack {
                Toggle(L("Mayúsculas"), isOn: $search.caseSensitive)
                Toggle(L("Palabras completas"), isOn: $search.wholeWords)
                Toggle(L("Versículos bíblicos"), isOn: $search.bibleVerses)
            }.disabled(search.isSearching)
            if let message = search.error { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if search.isSearching {
                HStack { ProgressView().controlSize(.small); Text(LF("{count} artículos examinados", ["count": String(search.progress?.counters.articlesExamined ?? 0)])) }
            }
            List(search.report?.results ?? []) { result in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(result.resourceTitle).font(.headline); Spacer(); Text(result.bibleReference ?? LF("Artículo {number}", ["number": String(result.sectionOrdinal + 1)])).font(.caption) }
                        Text(result.snippet.text).lineLimit(3).foregroundStyle(.secondary)
                        Text(LF("{count} coincidencias", ["count": String(result.hitCount)])).font(.caption)
                    }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Abrir")) { workspace.openSearchResult(result) }
                }.contentShape(Rectangle()).onTapGesture(count: 2) { workspace.openSearchResult(result) }
            }
            if let report = search.report {
                Text(LF("{results} resultados · {articles} artículos examinados", ["results": String(report.counters.resultsReturned), "articles": String(report.counters.articlesExamined)])).font(.caption)
                if !report.coverageComplete {
                    DisclosureGroup(L("La búsqueda tiene resultados parciales o recursos pendientes")) {
                        ScrollView {
                            Text(([report.limitReason.map { "Se alcanzó el límite de \($0.rawValue)." }].compactMap { $0 } + report.resourceReports.filter { $0.status != .complete }.map { "\($0.resourceTitle): \($0.warnings.joined(separator: " ")) \($0.errors.map(\.message).joined(separator: " "))" }).joined(separator: "\n"))
                                .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }
                }
            }
        }.padding(16).onDisappear(perform: search.cancel)
    }
}

struct ResourceInformationView: View {
    let reader: ReaderSession?
    var body: some View {
        ScrollView {
            if let reader {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                    row("Título", reader.resource.title)
                    row("Autor", reader.resource.author ?? "")
                    row("Idiomas", reader.resource.languages.joined(separator: ", "))
                    row("Formato", reader.resource.format.displayName)
                    row("Archivo", reader.resource.location.path)
                    row("Tamaño", ByteCountFormatter.string(fromByteCount: reader.resource.byteCount, countStyle: .file))
                    if let page = reader.page {
                        row("Ubicación", reader.currentReference ?? "Artículo \(page.destination.ordinal + 1)")
                        row("Artículos", String(page.sectionCount))
                        row("Imágenes del artículo", String(page.graphics.count))
                    }
                }.textSelection(.enabled).padding(20)
            } else { Text(L("Abre un recurso para ver sus propiedades.")).padding() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ label: String, _ value: String) -> some View { GridRow { Text(L(label)).foregroundStyle(.secondary); Text(value).frame(maxWidth: .infinity, alignment: .leading) } }
}

struct ResourceManagerView: View {
    @Bindable var workspace: StudyWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LF("{count} recursos", ["count": String(workspace.resources.count)])).font(.headline)
                Spacer()
                ResourceDirectoryButton(workspace: workspace)
                Button(L("Agregar carpeta…"), action: workspace.chooseLibrary)
            }
            Text(L("Los recursos LSF disponibles se abren localmente. Los formatos que aún requieren un lector y los servicios de licencias que no están disponibles se indican en cada recurso."))
                .font(.callout).foregroundStyle(.secondary)
            List(workspace.resources) { resource in
                HStack {
                    VStack(alignment: .leading) { Text(resource.title); Text(resource.fileName).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(resource.format == .legacyLSF ? "Lector LSF disponible" : resource.format == .libronixLLS ? "Contenedor Libronix disponible" : "Lector OEB pendiente").font(.caption).foregroundStyle(.secondary)
                    Button(L("Abrir")) { workspace.open(resource); workspace.activeTool = nil }
                }
            }
            Text(L("El servicio original de desbloqueo de licencias todavía no tiene una implementación verificada.")).font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

struct WorkspaceFavoritesView: View {
    @Bindable var workspace: StudyWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Button(L("Agregar ubicación actual"), action: workspace.addFavorite).disabled(workspace.activeReader?.page == nil); Spacer() }
            List {
                ForEach(workspace.personal.favorites.items) { favorite in
                    HStack {
                        MacToolbarLabel(favorite.kind == .folder ? "Carpeta" : "Favorito", favorite.kind == .folder ? "folder" : "bookmark")
                        TextField(L("Título"), text: Binding(get: { workspace.personal.favorites.items.first { $0.id == favorite.id }?.title ?? "" }, set: { value in
                            do { try workspace.personal.favorites.rename(favorite.id, title: value); workspace.savePersonal() } catch { workspace.error = error.localizedDescription }
                        }))
                        Button(L("Abrir")) { workspace.openFavorite(favorite) }.disabled(favorite.kind != .location)
                        Button { workspace.personal.favorites.remove(favorite.id); workspace.savePersonal() } label: { MacToolbarLabel(L("Eliminar favorito"), "trash") }.help(L("Eliminar favorito"))
                    }
                }
            }
        }.padding(16)
    }
}
