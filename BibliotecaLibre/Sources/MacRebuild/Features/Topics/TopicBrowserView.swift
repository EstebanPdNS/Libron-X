import SwiftUI
import LibronixCore

struct TopicBrowserView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var query = ""
    @RebuildViewState private var search = TopicSearchController()
    @RebuildViewState private var scope = TopicResourceScope.library
    @RebuildViewState private var mode = TopicSearchMode.associated
    @RebuildViewState private var selectedArticleID: String?
    @FocusState private var queryFocused: Bool
    @AppStorage("mac.topics.keepOpen.v1") private var keepOpen = false
    private func runSearch() { search.search(query, resources: scope.resources(in: workspace.availableResources),mode:mode) }
    private var selectedArticle: TopicEntry? { search.entries.first { $0.id == selectedArticleID } }
    private func open(_ item: TopicEntry) {
        workspace.open(item.resource, destination: .init(ordinal: item.entry.sectionOrdinal))
        if !keepOpen { workspace.activeTool = nil }
    }
    private var articleList: some View {
        List(selection: $selectedArticleID) {
            ForEach(search.entries) { item in
                Button { open(item) } label: {
                    VStack(alignment: .leading) {
                        Text(item.entry.displayTitle)
                        Text(item.resource.title).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.link)
                .accessibilityLabel(item.entry.displayTitle + " — " + item.resource.title)
                .accessibilityAction(named: Text(L("Abrir"))) { open(item) }
                .tag(item.id)
            }
        }
        .onKeyPress(.return) {
            guard let item = selectedArticle else { return .ignored }
            open(item); return .handled
        }
        .accessibilityLabel(L(mode == .associated ? "Artículos asociados" : "Título de artículo"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Tipo de búsqueda"),selection:$mode) {
                Text(L("Temas asociados")).tag(TopicSearchMode.associated)
                Text(L("Título de artículo")).tag(TopicSearchMode.titles)
            }.pickerStyle(.segmented)
            HStack {
                TextField(L(mode == .associated ? "Inicio del tema" : "Título de artículo"), text: $query)
                    .macInputStyle().focused($queryFocused).onSubmit(runSearch)
                Button(L(search.isLoading ? "Cancelar" : "Buscar")) { if search.isLoading { search.cancel() } else { runSearch() } }
            }
            Picker(L("Buscar en"), selection: $scope) {
                Text(L("Toda la biblioteca")).tag(TopicResourceScope.library)
                ForEach(workspace.availableResources.filter(TopicDirectorySource.supports)) { resource in
                    Text(resource.title).tag(TopicResourceScope.resource(resource.id))
                }
            }
            if mode == .associated {
                Text(L("Selecciona un tema para ver sus artículos asociados.")).font(.callout).foregroundStyle(.secondary)
                HSplitView {
                    List(selection:Binding(get:{search.selectedTopicGroupID},set:{search.selectTopicGroup($0)})) {
                        ForEach(search.topicGroups) { item in
                            VStack(alignment:.leading) {
                                Text(item.text)
                                Text((item.resourceCount == 1 ? item.members[0].resource.title : LF("{count} recursos", ["count":String(item.resourceCount)])) + (item.indexName == "topics" ? "" : " · " + item.indexName))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.tag(item.id)
                        }
                    }.frame(minWidth:180).accessibilityLabel(L("Temas asociados"))
                    articleList.frame(minWidth:220)
                    }
            } else { articleList }
            HStack {
                if search.isLoading { ProgressView().controlSize(.small) }
                Text(search.status.message(language: AppPreferences.shared.language, maximumResults: search.maximumResults)).font(.caption)
            }
            if search.topicResultsLimited {
                Text(L("La lista de temas es parcial; puede haber más artículos en otros recursos.")).font(.caption).foregroundStyle(.secondary)
            }
            if !search.failures.isEmpty {
                DisclosureGroup(L("Recursos no disponibles")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(search.failures) { failure in
                                Text(failure.resource.title + ": " + failure.message).font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
            }
            HStack {
                Toggle(L("Mantener abierto"), isOn: $keepOpen).toggleStyle(.checkbox)
                Spacer()
                Button(L("Abrir")) { if let item = selectedArticle { open(item) } }.disabled(selectedArticle == nil)
                Button(L("Cerrar")) { workspace.activeTool = nil }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).onDisappear(perform: search.cancel)
            .onAppear { queryFocused = true }
            .onChange(of: search.entries.map(\.id)) { selectedArticleID = nil }
            .onChange(of: mode) { search.libraryDidChange() }
            .onChange(of: scope) { search.libraryDidChange() }
            .onChange(of: workspace.availableResources.map(\.id)) {
                search.libraryDidChange()
            }
    }
}
