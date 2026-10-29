import AppKit
import SwiftUI
import LibronixCore

struct WorkspaceToolsView: View {
    let tool: WorkspaceTool
    @Bindable var workspace: StudyWorkspace
    var body: some View {
        VStack(spacing: 0) {
            MacToolHeader(title: title) { workspace.closeActiveTool() }.padding(16)
            Divider()
            switch tool {
            case .search: WorkspaceSearchView(workspace: workspace, search: workspace.search)
            case .referenceSearch: WorkspaceReferenceSearchView(workspace: workspace, search: workspace.referenceSearch)
            case .annotationSearch: PersonalAnnotationSearchView(workspace: workspace, search: workspace.annotationSearch)
            case .documents: WorkspaceDocumentsView(workspace: workspace, personal: workspace.personal)
            case .favorites: WorkspaceFavoritesView(workspace: workspace)
            case .readingPlans: ReadingPlansView(workspace: workspace)
            case .prayerJournal: PrayerJournalView(personal: workspace.personal)
            case .scriptureMemory: ScriptureMemoryView(workspace: workspace, personal: workspace.personal)
            case .studyAssessments: StudyAssessmentView(personal: workspace.personal)
            case .wordSearch: WordSearchView()
            case .commandPalette: WorkspaceCommandPaletteView(workspace: workspace)
            case .biblicalMeasures: BiblicalMeasuresView()
            case .researchInbox: ResearchInboxView(workspace: workspace, personal: workspace.personal)
            case .transliteration:
                TransliterationView(controller: workspace.transliteration, search: workspace.search) { workspace.activeTool = .search }
            case .libraryHealth: LibraryHealthView(workspace: workspace)
            case .passageGuide: PassageGuideView(workspace: workspace, controller: workspace.passageGuide)
            case .information: ResourceInformationView(reader: workspace.activeReader)
            case .resources: ResourceManagerView(workspace: workspace)
            case .topics: TopicBrowserView(workspace: workspace)
            case .bibleCopy: BibleCopyToolView(workspace: workspace)
            case .windows: WorkspaceWindowsView(workspace: workspace)
            case .bibliography: BibliographyView(workspace:workspace,controller:workspace.bibliography)
            case .editions: LibraryEditionsView(workspace:workspace,controller:workspace.editions)
            case .associationLinks: AssociatedResourcesView(workspace: workspace, controller: workspace.associationNavigation)
            case .associations: ResourceAssociationSettingsView(workspace: workspace)
            case .parallelSets: ParallelBibleSettingsView(workspace: workspace)
            case .keyLinks: KeyLinkView(workspace: workspace, controller: workspace.keyLinks)
            case .passageComparison: PassageComparisonView(workspace: workspace, controller: workspace.passageComparison)
            }
        }.frame(minWidth: tool == .information ? 700 : 680, idealWidth: tool == .information ? 700 : 820,
                minHeight: compactComparison || compactAnnotationSearch || compactReadingPlans || compactPassageGuide || tool == .information || tool == .libraryHealth ? nil : tool == .bibliography ? 640 : tool == .search ? 680 : expandedScope ? 620 : 520,
                idealHeight: compactComparison || compactAnnotationSearch || compactReadingPlans || compactPassageGuide || tool == .information || tool == .libraryHealth ? nil : tool == .bibliography ? 820 : tool == .search ? 820 : expandedScope ? 720 : 620)
            .modifier(MacPanelControlPresentation())
            .alert("Libron-X", isPresented: Binding(get: { tool == .favorites && workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
                Button(L("Aceptar")) { workspace.error = nil }
            } message: { Text(workspace.error ?? "") }
    }
    private var compactAnnotationSearch: Bool {
        tool == .annotationSearch && workspace.annotationSearch.report == nil && !workspace.annotationSearch.isSearching
    }
    private var compactReadingPlans: Bool { tool == .readingPlans && workspace.personal.readingPlans.plans.isEmpty }
    private var compactPassageGuide: Bool { tool == .passageGuide && !workspace.passageGuide.completed && workspace.passageGuide.matches.isEmpty && workspace.passageGuide.references == nil }
    private var compactComparison: Bool {
        tool == .passageComparison && !workspace.passageComparison.completed && !workspace.passageComparison.isLoading
    }
    private var expandedScope: Bool {
        let kind: WorkspaceSearchScopeKind?
        if tool == .search { kind = workspace.search.scope.kind }
        else if tool == .referenceSearch && workspace.referenceSearch.includeLibrary { kind = workspace.referenceSearch.scope.kind }
        else { kind = nil }
        return kind == .collections || kind == .subset
    }
    private var title: String {
        switch tool {
        case .search: "Buscar"
        case .referenceSearch: "Buscar referencias bíblicas"
        case .annotationSearch: "Buscar notas y resaltados"
        case .documents: "Documentos de estudio"
        case .favorites: "Favoritos"
        case .readingPlans: "Planes de lectura"
        case .prayerJournal: "Lista de oración"
        case .scriptureMemory: "Memorización de pasajes"
        case .studyAssessments: "Autoevaluaciones"
        case .wordSearch: "Sopa de letras"
        case .commandPalette: "Paleta de comandos"
        case .biblicalMeasures: "Pesos y medidas bíblicos"
        case .researchInbox: "Bandeja de investigación"
        case .transliteration: "Transliteración"
        case .libraryHealth: "Salud de la biblioteca"
        case .passageGuide: "Guía de pasajes"
        case .information: "Propiedades del recurso"
        case .resources: "Recursos y licencias"
        case .topics: "Explorador temático"
        case .bibleCopy: "Copiar versículos bíblicos"
        case .windows: "Ventanas"
        case .bibliography: "Bibliografía"
        case .editions: "Duplicados y ediciones"
        case .associationLinks: "Recursos asociados"
        case .associations: "Asociaciones de recursos"
        case .parallelSets: "Grupos de Biblias paralelas"
        case .keyLinks: "Enlaces clave"
        case .passageComparison: "Comparar pasajes bíblicos"
        }
    }
}

struct WorkspaceSearchView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var search: WorkspaceSearchController
    @RebuildViewState private var historyOpen = false
    @RebuildViewState private var savedQueriesOpen = false
    @RebuildViewState private var namedRangesOpen = false
    private func run() { search.run(workspace.availableResources, documents: workspace.personal.documents, namedRanges: workspace.personal.namedBibleRanges.ranges, scopeContext: workspace.searchScopeContext()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L(search.approximatePhrase ? "Frase literal" : "Palabra, frase entre comillas o consulta AND / OR"), text: $search.query).macInputStyle()
                    .onSubmit(run).disabled(search.isSearching)
                if search.isSearching {
                    if search.phase == .paused { Button(L("Reanudar"), action: search.resume) }
                    else { Button(L("Pausar"), action: search.pause).disabled(search.phase != .running) }
                    Button(L("Cancelar"), action: search.cancel).disabled(search.phase == .cancelling)
                }
                else { Button(L("Buscar"), action: run).disabled(search.query.isEmpty) }
            }
            HStack {
                Button(L("Historial de búsquedas…")) { historyOpen = true }
                Button(L("Consultas guardadas…")) { savedQueriesOpen = true }
                Button { workspace.activeTool = .transliteration } label: {
                    Label(L("Transliteración"), systemImage: "character.book.closed")
                }
                Spacer()
            }.disabled(search.isSearching)
            WorkspaceSearchScopePicker(selection: search.scope, context: workspace.searchScopeContext()).disabled(search.isSearching)
            WorkspaceSearchFieldPicker(field: $search.searchField).disabled(search.isSearching)
            WorkspaceSearchMatchingPicker(search: search).disabled(search.isSearching)
            WorkspaceWordFiltersView(search: search, personal: workspace.personal)
            WorkspaceSearchLimitsView(search: search)
            if search.bibleVerses {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("Rango bíblico"), selection: $search.bibleRangeMode) {
                        Text(L("Todos los versículos")).tag(WorkspaceBibleRangeMode.all)
                        Text(L("Pasajes o libros")).tag(WorkspaceBibleRangeMode.custom)
                        Text(L("Lista guardada")).tag(WorkspaceBibleRangeMode.savedList)
                        Text(L("Rango guardado")).tag(WorkspaceBibleRangeMode.namedRange)
                    }
                    if search.bibleRangeMode == .custom {
                        TextField(L("Pasajes, por ejemplo Gn 1–3; Juan 3:16–18; Romanos"), text: $search.customBibleRange)
                            .macInputStyle().onSubmit(run)
                    } else if search.bibleRangeMode == .savedList {
                        Picker(L("Lista de versículos"), selection: $search.referenceListID) {
                            Text(L("Selecciona una lista de versículos")).tag(Optional<UUID>.none)
                            ForEach(workspace.personal.documents.filter { $0.kind == .verseList }) {
                                Text($0.title).tag(Optional($0.id))
                            }
                        }
                    } else if search.bibleRangeMode == .namedRange {
                        Picker(L("Rango guardado"), selection: $search.namedRangeID) {
                            Text(L("Selecciona un rango guardado")).tag(Optional<UUID>.none)
                            ForEach(workspace.personal.namedBibleRanges.ranges) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Picker(L("Excluir referencias"), selection: $search.excludedRange.mode) {
                        Text(L("Sin exclusiones")).tag(WorkspaceBibleRangeMode.all)
                        Text(L("Pasajes o libros")).tag(WorkspaceBibleRangeMode.custom)
                        Text(L("Lista guardada")).tag(WorkspaceBibleRangeMode.savedList)
                        Text(L("Rango guardado")).tag(WorkspaceBibleRangeMode.namedRange)
                    }
                    if search.excludedRange.mode == .custom {
                        TextField(L("Pasajes, por ejemplo Gn 1–3; Juan 3:16–18; Romanos"), text: $search.excludedRange.customRange)
                            .macInputStyle().onSubmit(run)
                    } else if search.excludedRange.mode == .savedList {
                        Picker(L("Lista de versículos excluidos"), selection: $search.excludedRange.referenceListID) {
                            Text(L("Selecciona una lista de versículos")).tag(Optional<UUID>.none)
                            ForEach(workspace.personal.documents.filter { $0.kind == .verseList }) {
                                Text($0.title).tag(Optional($0.id))
                            }
                        }
                    } else if search.excludedRange.mode == .namedRange {
                        Picker(L("Rango excluido"), selection: $search.excludedRange.namedRangeID) {
                            Text(L("Selecciona un rango guardado")).tag(Optional<UUID>.none)
                            ForEach(workspace.personal.namedBibleRanges.ranges) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Button(L("Gestionar rangos…")) { namedRangesOpen = true }
                }.disabled(search.isSearching)
            }
            HStack {
                Toggle(L("Mayúsculas"), isOn: $search.caseSensitive)
                Toggle(L("Palabras completas"), isOn: $search.wholeWords)
                Toggle(L("Versículos bíblicos"), isOn: $search.bibleVerses)
            }.disabled(search.isSearching)
            if !search.approximatePhrase {
            DisclosureGroup(L("Operadores de búsqueda")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "title:a · body:(a AND b) · footnote:a\nheading:a · bible:a · quote:a")
                    Text(verbatim: "a NEAR b · a NEAR/2 b · a BEFORE b · a AFTER b\na WITHIN 2 WORDS b · a BEFORE 2 CHARACTERS b\na WITHIN 1 VERSES b · (a OR b) BEFORE/0 c")
                    Text(L("NEAR usa 48 unidades UTF-16. WORDS cuenta palabras intermedias. VERSES usa referencias reales del mismo capítulo. Cada artículo o versículo conserva su ámbito."))
                }.font(.caption).textSelection(.enabled)
            }
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: search.isSearching || search.report != nil ? 300 : 480).layoutPriority(1)
            if let message = search.error { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if let message = search.historyError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if search.report == nil, let scope = search.scopeSnapshot, !scope.complete {
                DisclosureGroup(L("La búsqueda tiene resultados parciales o recursos pendientes")) {
                    ScrollView { Text(scope.issueLines.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 100)
                }
            }
            WorkspaceSearchRunStatusView(search: search)
            if let query = search.submittedQuery, search.report != nil {
                Text(LF("Resultados de: {query}", ["query": query])).font(.caption).lineLimit(2)
            }
            if search.configurationChanged {
                Text(L("La configuración cambió. Ejecuta una búsqueda nueva para abrir estos resultados."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if search.report != nil {
                WorkspaceSearchResultsView(workspace: workspace, search: search, presentation: search.presentation)
            }
            if let report = search.report {
                if let scope = search.scopeSnapshot { Text(scope.description).font(.caption).lineLimit(2) }
                if report.unit == .bibleVerse {
                    Text(LF("Rango: {range}", ["range": report.bibleRange?.description ?? L("Todos los versículos")])).font(.caption)
                    if let excluded = report.excludedBibleRange {
                        Text(LF("Referencias excluidas: {range}", ["range": excluded.description])).font(.caption)
                    }
                    Text(LF("{selected} versículos examinados · {excluded} fuera del rango", ["selected": String(report.counters.versesExamined), "excluded": String(report.counters.versesExcludedByRange)])).font(.caption)
                }
                Text(LF("{results} resultados · {articles} artículos examinados", ["results": String(report.counters.resultsReturned), "articles": String(report.counters.articlesExamined)])).font(.caption)
                if !search.coverageComplete {
                    DisclosureGroup(L("La búsqueda tiene resultados parciales o recursos pendientes")) {
                        ScrollView {
                            Text(((search.scopeSnapshot?.issueLines ?? []) + [report.limitReason.map { LF("Se alcanzó el límite de {limit}.", ["limit": $0.localizedTitle]) }].compactMap { $0 } + report.resourceReports.filter { $0.status != .complete }.map { "\($0.resourceTitle): \($0.warnings.joined(separator: " ")) \($0.errors.map(\.message).joined(separator: " "))" }).joined(separator: "\n"))
                                .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(16).onDisappear(perform: search.pause)
            .onChange(of: workspace.personal.namedBibleRanges) { old, new in search.namedRangesChanged(from: old, to: new) }
            .sheet(isPresented: $historyOpen) {
                WorkspaceSearchHistoryView(history: workspace.personal.searchHistory, search: search).modifier(AppInterfaceLanguage())
            }
            .sheet(isPresented: $savedQueriesOpen) {
                WorkspaceSavedQueriesView(store: workspace.personal.savedQueries, search: search).modifier(AppInterfaceLanguage())
            }
            .sheet(isPresented: $namedRangesOpen) {
                NamedBibleRangesView(personal: workspace.personal).modifier(AppInterfaceLanguage())
            }
    }
}

struct ResourceInformationView: View {
    let reader: ReaderSession?
    @RebuildViewState private var contentHeight: CGFloat = 480
    @RebuildViewState private var indexCount: Int?
    @RebuildViewState private var normalization: LibronNormalizationReceipt?
    @RebuildViewState private var indexError: String?
    @RebuildViewState private var detailsExpanded = false
    private let fields: [LibraryField] = [.author, .language, .type, .category, .subcategory, .year,
        .publisher, .edition, .collection, .origin, .tags, .coverage]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let reader {
                    let resource = reader.resource
                    let metadata = LibronMetadata.deriving(resource)
                    HStack(alignment: .top, spacing: 14) {
                        Group {
                            if let kind = StudyResourceKind.identifying(reader) { StudyResourceIcon(kind: kind, size: 28) }
                            else { Image(systemName: "book.closed").font(.system(size: 28)) }
                        }.foregroundStyle(.tint).frame(width: 44, height: 48)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metadata.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            if let subtitle = metadata.subtitle, !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
                            Text(resource.packageLocation == nil ? resource.format.displayName : ".libron")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 14) {
                        ForEach(fields) { field in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L(field.title)).font(.caption).foregroundStyle(.secondary)
                                let value = field.value(resource)
                                Text(value.isEmpty ? "—" : value).frame(maxWidth: .infinity, alignment: .leading)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if reader.isDictionary {
                        Divider()
                        HStack {
                            Label(L("Índice de palabras"), systemImage: "text.book.closed")
                            Spacer()
                            if let indexCount { Text(LF("{count} entradas", ["count": indexCount.formatted()])).foregroundStyle(.secondary) }
                            else if let indexError { Text(indexError).font(.caption).foregroundStyle(.secondary) }
                            else { ProgressView().controlSize(.small) }
                        }
                    }
                    if let page = reader.page {
                        Divider()
                        HStack(alignment: .top, spacing: 24) {
                            statistic("Ubicación", reader.currentReference ?? LF("Artículo {number}", ["number": String(page.destination.ordinal + 1)]))
                            statistic("Artículos", page.sectionCount.formatted())
                            statistic("Imágenes del artículo", page.graphics.count.formatted())
                        }
                    }
                    Divider()
                    DisclosureGroup(L("Detalles del archivo"), isExpanded: $detailsExpanded) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                            detail("Formato original", resource.format.displayName)
                            if let normalization {
                                detail("Estado de conversión", L(normalization.state == "complete" ? "Contenido nativo verificado" : "Conversión pendiente"))
                                detail("Secciones verificadas", "\(normalization.checkedSections) / \(normalization.sections)")
                                if !normalization.warnings.isEmpty { detail("Advertencias de conversión",normalization.warnings.joined(separator:"\n")) }
                            }

                            detail("Tamaño", ByteCountFormatter.string(fromByteCount: resource.byteCount, countStyle: .file))
                            if let package = resource.packageLocation { detail("Paquete .libron", package.path) }
                            detail("Archivo", resource.location.path)
                            ForEach([LibraryField.contributors, .originalYear]) { field in
                                let value = field.value(resource)
                                if !value.isEmpty { detail(field.title, value) }
                            }
                            if let abbreviation = metadata.abbreviation { detail("Abreviatura", abbreviation) }
                            if let originalTitle = metadata.originalTitle { detail("Título original", originalTitle) }
                            ForEach(Array(metadata.evidence.filter { ["license", "source"].contains($0.field) }.enumerated()), id: \.offset) { _, evidence in
                                detail(evidence.field == "license" ? "Licencia" : "Origen", evidence.value)
                            }
                        }.padding(.top, 10)
                    }
                } else { Text(L("Abre un recurso para ver sus propiedades.")) }
            }.textSelection(.enabled).padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }.frame(width: 700, height: min(contentHeight, max(320, (NSScreen.main?.visibleFrame.height ?? 900) * 0.72)))
            .task(id: reader?.resource.id) {
                indexCount = nil; indexError = nil; normalization = nil
                if let package = reader?.resource.packageLocation,
                   let data = try? Data(contentsOf:package.appendingPathComponent("normalized/conversion.json")) {
                    normalization = try? JSONDecoder().decode(LibronNormalizationReceipt.self,from:data)
                }
                guard let reader, reader.isDictionary else { return }
                do {
                    if reader.resource.format == .libronDictionary { indexCount = try LibronDictionaryDatabase.count(reader.resource.location) }
                    else { indexCount = try await LibronDictionaryIndexService.shared.index(reader.resource).entries.count }
                }
                catch { indexError = error.localizedDescription }
            }
    }
    private func statistic(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(label)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func detail(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(L(label)).foregroundStyle(.secondary)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }.font(.callout)
    }
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
                    Text(L("Formato") + ": " + resource.format.displayName).font(.caption).foregroundStyle(.secondary)
                    Button(L("Abrir")) { workspace.open(resource); workspace.activeTool = nil }
                }
            }
            Text(L("El servicio original de desbloqueo de licencias todavía no tiene una implementación verificada.")).font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}
