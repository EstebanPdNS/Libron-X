import SwiftUI
import LibronixCore

struct MainWorkspaceToolbar: ToolbarContent {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.openWindow) private var openWindow
    @ToolbarContentBuilder var body: some ToolbarContent {
        leadingItems
        documentAndResourceItems
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItemGroup {
            ReaderZoomMenu(reader: workspace.activeReader)
            Menu {
                Button(L("Agregar ubicación actual"), action: workspace.addFavorite).disabled(workspace.activeReader?.page == nil)
                Button(L("Organizar favoritos…")) { workspace.activeTool = .favorites }
                Divider()
                ForEach(workspace.personal.favorites.items.filter { $0.kind == .location }) { favorite in
                    Button(favorite.title) { workspace.openFavorite(favorite) }
                }
            } label: { MacToolbarMenuLabel(L("Favoritos"), "star") }.help(L("Favoritos"))
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItemGroup {
            MacToolbarButton(L("Duplicar lectura"), "plus.square.on.square") {
                if let reader = workspace.activeReader { workspace.duplicate(reader) }
            }.disabled(workspace.activeReader?.page == nil)
            BibleSynchronizationMenu(workspace: workspace, reader: workspace.activeReader.flatMap { $0.canSynchronizeBible ? $0 : nil } ?? workspace.bibleReaders.first)
            PaneLayoutPicker(workspace: workspace)
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItemGroup {
            MacToolbarButton(L("Descargas"), "arrow.down.circle") { AppUpdater.shared.showsPanel = true }
            MacToolbarButton(L("Administrar recursos y licencias"), "externaldrive") { workspace.activeTool = .resources }
            MacToolbarButton(L("Propiedades del recurso"), "info.circle") { workspace.activeTool = .information }
                .disabled(workspace.activeReader == nil)
        }
        if workspace.isImporting {
            ToolbarItem(placement: .status) {
                HStack { ProgressView().controlSize(.small); Text(workspace.importProgress).font(.caption) }
            }
        }
    }
    @ToolbarContentBuilder private var documentAndResourceItems: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button(L("Archivo de notas")) { workspace.newDocument(.notebook) }
                Button(L("Lista de versículos")) { workspace.newDocument(.verseList) }
            } label: { MacToolbarMenuLabel(L("Nuevo documento"), "square.and.pencil") }
                .help(L("Nuevo documento"))
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItemGroup {
            ForEach(StudyResourceKind.allCases, id: \.self) { kind in
                StudyResourcePickerButton(workspace: workspace, kind: kind)
            }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItemGroup {
            Menu {
                Button(L("Documento de estudio…"), action: workspace.openDocument)
                Button(L("Área de trabajo…"), action: workspace.openWorkspace)
                Button(L("Carpeta de recursos…"), action: workspace.chooseLibrary)
                Button(L("Abrir directorio actual")) { workspace.openCurrentResourceDirectory() }
                    .disabled(workspace.currentResourceDirectory == nil)
            } label: { MacToolbarMenuLabel(L("Abrir"), "folder") }.help(L("Abrir"))
            MacToolbarButton(L("Cargar área de trabajo"), "rectangle.stack", action: workspace.openWorkspace)
            MacToolbarButton(L("Guardar área de trabajo"), "square.and.arrow.down", action: workspace.saveWorkspace)
        }
    }
    @ToolbarContentBuilder private var leadingItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            MacToolbarButton(L("Inicio"), "house", horizontalInset: 4) { workspace.showsHome.toggle() }
            MacToolbarButton(L("Mi biblioteca"), "books.vertical", horizontalInset: 4) {
                workspace.pendingLibraryReference = nil; openWindow(id: "library")
            }
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItem(placement: .navigation) { searchField }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { searchField }
        }
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { MacApplicationIdentity() }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { MacApplicationIdentity() }
        }
        ToolbarItem(placement: .principal) { Spacer(minLength: 0) }
        if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
        ToolbarItemGroup {
            MacToolbarButton(L("Explorador temático"), "tag") { workspace.activeTool = .topics }
            MacToolbarButton(L("Copiar versículos bíblicos"), "doc.on.clipboard") { workspace.activeTool = .bibleCopy }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
    }

    private var searchField: some View {
        MacToolbarSearchField(text: $workspace.search.query, prompt: L("Buscar"), onSubmit: workspace.submitToolbarSearch)
            .frame(width: 240, height: 32).modifier(MacToolbarSearchSurface())
            .help(L("Palabra, frase entre comillas o consulta AND / OR"))
    }

}

struct ReaderZoomMenu: View {
    var reader: ReaderSession?
    var activate: () -> Void = {}
    @RebuildViewState private var expanded = false
    var body: some View {
        Button { activate(); expanded.toggle() } label: { MacToolbarLabel(L("Zoom del texto"), "textformat.size") }
            .help(L("Zoom del texto")).disabled(reader == nil)
            .macToolbarPopover(isPresented: $expanded, size: NSSize(width: 332, height: 145)) {
                if let reader { ReaderZoomSlider(reader: reader) }
            }
    }
}
struct ReaderZoomSlider: View {
    @Bindable var reader: ReaderSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Zoom del texto")).font(.headline)
                HelpButton(topic: .zoom)
                Spacer()
                Text("\(Int((reader.textScale * 100).rounded())) %").monospacedDigit()
            }
            Slider(value: Binding(get: { reader.textScale * 100 }, set: {
                if let scale = ReaderZoom.sliderScale(for: $0) { reader.textScale = scale }
            }), in: 0...300, step: 5)
                .accessibilityLabel(L("Zoom del texto"))
                .accessibilityValue("\(Int((reader.textScale * 100).rounded())) %")
            HStack {
                Text("0 %").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("100 %") { reader.textScale = 1 }.controlSize(.small).help(L("Restaurar tamaño del texto"))
                Spacer()
                Text("300 %").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(width: 300).modifier(MacPanelControlPresentation()).featureHelpTarget(.reading)
    }
}
struct ReaderMarkupMenu: View {
    @Bindable var workspace: StudyWorkspace
    var reader: ReaderSession? = nil
    @RebuildViewState private var expanded = false
    @RebuildViewState private var markStyle: ReaderMarkStyle?
    @RebuildViewState private var showsPalettes = false
    private var target: ReaderSession? { reader ?? workspace.activeReader }
    var body: some View {
        Button {
            if let target { workspace.activate(target) }
            expanded.toggle()
        } label: { MacToolbarLabel("Marcación visual", "highlighter") }
            .help(L("Marcación visual"))
            .macToolbarPopover(isPresented: $expanded, size: NSSize(width: 280, height: 242)) {
                ReaderMarkupPopover(workspace: workspace, personal: workspace.personal, target: target,
                                    style: $markStyle, expanded: $expanded, showsPalettes: $showsPalettes)
            }
            .sheet(isPresented: $showsPalettes) { MarkPalettesView(personal: workspace.personal).modifier(AppInterfaceLanguage()) }
    }
}

/// Its own observed view is hosted inside the native popover so a palette
/// change updates the color buttons immediately while the popover is open.
private struct ReaderMarkupPopover: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var personal: WorkspacePersonalState
    let target: ReaderSession?
    @Binding var style: ReaderMarkStyle?
    @Binding var expanded: Bool
    @Binding var showsPalettes: Bool
    private let styles: [(ReaderMarkStyle?, String, String)] = [
        (nil, "Resaltado", "highlighter"),
        (.underline, "Subrayado", "underline"),
        (.strike, "Tachado", "strikethrough"),
        (.outline, "Contorno", "rectangle")
    ]
    private var selection: Binding<UUID?> {
        Binding(get: { personal.markPalettes.selectedID }, set: { value in
            do { try personal.editMarkPalettes { $0.selectedID = value } }
            catch { workspace.error = error.localizedDescription }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker(L("Paleta"), selection: selection) {
                    Text(L("Colores predeterminados")).tag(Optional<UUID>.none)
                    ForEach(personal.markPalettes.palettes) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: .infinity)
                Button { expanded = false; showsPalettes = true } label: {
                    Label(L("Gestionar paletas"), systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
                }.help(L("Gestionar paletas"))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(styles.indices, id: \.self) { index in
                    let choice = styles[index]
                    Toggle(isOn: Binding(get: { style == choice.0 }, set: { if $0 { style = choice.0 } })) {
                        VStack(spacing: 4) {
                            Image(systemName: choice.2).font(.system(size: 16, weight: .medium))
                            Text(L(choice.1)).font(.caption).lineLimit(1).minimumScaleFactor(0.85)
                        }.frame(maxWidth: .infinity, minHeight: 40)
                    }.toggleStyle(.button).buttonBorderShape(.roundedRectangle(radius: 10))
                        .accessibilityLabel(L(choice.1))
                }
            }.accessibilityLabel(L("Estilo de marcación"))
            Divider()
            HStack(spacing: 6) {
                ForEach(personal.markPalettes.selectedColors, id: \.self) { color in
                    Button {
                        if let target { workspace.activate(target) }
                        workspace.addHighlight(color.rawValue, style: style); expanded = false
                    } label: {
                        if #available(macOS 26, *) { Color.clear.frame(width: 22, height: 28) }
                        else { Capsule().fill(color.color).frame(width: 22, height: 28) }
                    }.tint(color.color).help(L(color.title)).accessibilityLabel(L(color.title))
                        .disabled((target?.selectedRange.length ?? 0) == 0).featureHelpTarget(.marks)
                }
                Divider().frame(height: 28)
                Button {
                    if let target { workspace.activate(target) }
                    workspace.eraseHighlight(); expanded = false
                } label: { Image(systemName: "trash").font(.system(size: 16)).frame(width: 22, height: 28) }
                    .help(L("Borrar marcación seleccionada"))
                    .disabled((target?.selectedRange.length ?? 0) == 0)
                    .accessibilityLabel(L("Borrar marcación seleccionada")).featureHelpTarget(.marks)
            }.controlSize(.regular)
        }.padding(12).modifier(MacPanelControlPresentation()).featureHelpTarget(.marks)
    }
}

struct ResourceReaderToolbar: View {
    @Bindable var reader: ReaderSession
    @Bindable var workspace: StudyWorkspace
    @Environment(\.openWindow) private var openWindow
    @RebuildViewState private var referenceDraft: String?
    @RebuildViewState private var chapterBooks: [BibleChapterBook] = []
    var body: some View {
        GeometryReader { geometry in
            MacReaderToolbarSurface {
                if reader.isDictionary { DictionaryReaderToolbar(reader: reader, workspace: workspace) }
                else {
                    HStack(spacing: 8) {
                        referenceField.frame(width: geometry.size.width >= 620 ? 120 : 90)
                        bookChapterControls(compact: geometry.size.width < 620)
                        Spacer(minLength: 4)
                        // Use the actual pane width, not competing mounted
                        // popover anchors in ViewThatFits. Zooming must never
                        // move a live popover between alternate toolbar trees.
                        if geometry.size.width >= (chapterBooks.isEmpty ? 820 : 1060) { compactControls }
                        else if geometry.size.width >= (chapterBooks.isEmpty ? 620 : 860) { mediumControls }
                        else if geometry.size.width >= (chapterBooks.isEmpty ? 400 : 650) { minimalControls }
                        else { essentialControls }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).frame(height: 44)
        .background(.bar)
        .transaction { $0.animation = nil }
        // A committed navigation (including linked-pane navigation) supersedes
        // an old editor draft; viewport-only updates must not erase typing.
        .onChange(of: reader.selectionRequest) { referenceDraft = nil }
        .task(id: reader.resource) {
            chapterBooks = []
            guard !reader.isDictionary else { return }
            chapterBooks = (try? await BibleChapterCatalog.shared.books(in: reader.resource)) ?? []
        }
    }
    private var compactControls: some View {
        HStack(spacing: 8) {
            versionControls
            MacReaderControlGroup { referenceTargetButton }
            MacReaderControlGroup {
                icon("Buscar en este recurso", "magnifyingglass") { reader.showFind() }
                icon("Contenido", "sidebar.left") { reader.showsContents.toggle() }
                zoomMenu
                noteButton
                ReaderMarkupMenu(workspace: workspace, reader: reader)
                actionsMenu(expanded: true)
            }
        }
    }
    private var mediumControls: some View {
        HStack(spacing: 8) {
            versionControls
            MacReaderControlGroup { referenceTargetButton }
            MacReaderControlGroup {
                icon("Buscar en este recurso", "magnifyingglass") { reader.showFind() }
                icon("Contenido", "sidebar.left") { reader.showsContents.toggle() }
                zoomMenu
                noteButton
                ReaderMarkupMenu(workspace: workspace, reader: reader)
                actionsMenu(expanded: true)
            }
        }
    }
    private var essentialControls: some View {
        MacReaderControlGroup {
            zoomMenu
            noteButton
            ReaderMarkupMenu(workspace: workspace, reader: reader)
            actionsMenu(expanded: true)
        }
    }
    private var minimalControls: some View {
        HStack(spacing: 6) {
            if reader.canSynchronizeBible { versionControls }
            MacReaderControlGroup {
                zoomMenu
                noteButton
                ReaderMarkupMenu(workspace: workspace, reader: reader)
                actionsMenu(expanded: true)
            }
        }
    }
    private var noteButton: some View {
        icon("Agregar nota", "square.and.pencil") { workspace.addNoteForSelection(reader) }
            .featureHelpTarget(.documents)
    }
    private var referenceField: some View {
        MacToolbarSearchField(text: Binding(get: { referenceDraft ?? reader.locator }, set: { referenceDraft = $0 }),
            prompt: L(reader.locatorIsArticle ? "Artículo" : "Referencia"),
            onSubmit: {
                if let referenceDraft { reader.locator = referenceDraft }
                referenceDraft = nil
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
                perform(reader.goToReference)
            }, onEditingBegan: {
                workspace.activate(reader)
            }, onEditingEnded: {
                if let referenceDraft { reader.locator = referenceDraft }
                referenceDraft = nil
            })
            .frame(height: 32).modifier(MacToolbarSearchSurface())
            .help(reader.locatorIsArticle ? L("Número de artículo") : "Génesis 4:1 · Gen 4.1 · Gn 4,1 · Génesis 4")
            .environment(\.layoutDirection, .leftToRight)
    }
    private var currentChapter: LegacyPassageQuery? {
        reader.currentReference.flatMap(LegacyPassageQuery.navigationInput)
    }
    @ViewBuilder private func bookChapterControls(inMenu: Bool = false, compact: Bool = false) -> some View {
        if !chapterBooks.isEmpty {
            let selected = chapterBooks.first { book in
                book.id == currentChapter?.sourceBookKey || book.sourceOrdinals?.values.contains(reader.page?.destination.ordinal ?? -1) == true
            } ?? chapterBooks.first!
            if inMenu {
                bookMenu(selected, inMenu: true)
                chapterMenu(selected, inMenu: true)
                if reader.strongVariant != nil { Toggle(L("Números Strong"), isOn: Binding(get: { reader.showsStrongNumbers }, set: { _ in perform(reader.toggleStrongNumbers) })) }
            } else {
                MacReaderControlGroup {
                    bookMenu(selected, inMenu: false, compact: compact)
                    Divider().frame(height: 16)
                    chapterMenu(selected, inMenu: false, compact: compact)
                    if reader.strongVariant != nil {
                        Divider().frame(height: 16)
                        Button { perform(reader.toggleStrongNumbers) } label: {
                            Text("Strong").font(.body)
                                .foregroundStyle(reader.showsStrongNumbers ? Color.accentColor : Color.primary)
                        }.help(L("Números Strong")).accessibilityLabel(L("Números Strong"))
                            .accessibilityValue(L(reader.showsStrongNumbers ? "Activado" : "Desactivado"))
                    }
                }
            }
        }
    }
    private func bookMenu(_ selected: BibleChapterBook, inMenu: Bool, compact: Bool = false) -> some View {
        Menu {
            ForEach(chapterBooks) { book in
                Button(book.title(language: AppLanguage.saved())) { navigate(book, chapter: book.chapters.first ?? 1) }
            }
        } label: {
            if compact { StudyResourceIcon(kind: .bible) }
            else { Text(inMenu ? L("Libro") : selected.title(language: AppLanguage.saved())).lineLimit(1).frame(maxWidth: inMenu ? nil : 112) }
        }.help(L("Libro")).accessibilityLabel(L("Libro")).featureHelpTarget(.bibleReading)
    }
    private func chapterMenu(_ selected: BibleChapterBook, inMenu: Bool, compact: Bool = false) -> some View {
        Menu {
            ForEach(selected.chapters, id: \.self) { chapter in
                Button(String(chapter)) { navigate(selected, chapter: chapter) }
            }
        } label: {
            let observedChapter = selected.sourceOrdinals?.first(where: { $0.value == reader.page?.destination.ordinal })?.key
            let chapter = observedChapter ?? currentChapter?.chapter ?? selected.chapters.first ?? 1
            Text(inMenu ? L("Capítulo") : (compact ? "" : L("Capítulo") + " ") + String(chapter)).monospacedDigit()
        }.help(L("Capítulo")).accessibilityLabel(L("Capítulo")).featureHelpTarget(.bibleReading)
    }
    private func navigate(_ book: BibleChapterBook, chapter: Int) {
        perform {
            if let ordinal = book.sourceOrdinals?[chapter] {
                reader.load(.init(ordinal: ordinal), propagateReference: false)
                return
            }
            reader.changeLocatorMode(false)
            reader.locator = book.reference(chapter: chapter)
            reader.goToReference()
        }
    }
    private var referenceMenu: some View {
        Menu {
            ForEach(references, id: \.self) { reference in
                Button(reference) { perform { reader.changeLocatorMode(false); reader.locator = reference; reader.goToReference() } }
            }
        } label: { MacToolbarLabel(L("Versículo"), "list.bullet") }
            .menuIndicator(.hidden).help(L("Versículo")).disabled(references.isEmpty)
    }
    private var locatorMenu: some View {
        Menu {
            Button((reader.locatorIsArticle ? "" : "✓ ") + L("Referencia bíblica")) { perform { reader.changeLocatorMode(false) } }
            Button((reader.locatorIsArticle ? "✓ " : "") + L("Artículo")) { perform { reader.changeLocatorMode(true) } }
        } label: { MacToolbarLabel(L("Índice activo"), "number") }.help(L("Índice activo")).menuIndicator(.hidden)
    }
    @ViewBuilder private var interlinearMenu: some View {
        if let lines = reader.page?.interlinearLines, !lines.isEmpty {
            Menu {
                ForEach(lines, id: \.ordinal) { line in
                    Button("\(reader.effectiveInterlinearLines.contains(line.ordinal) ? "✓ " : "")\(line.label)") { perform { reader.toggleInterlinearLine(line.ordinal) } }
                }
                Divider()
                Button(L("Mostrar todas las líneas")) { perform { reader.visibleInterlinearLines = Set(lines.map(\.ordinal)) } }
                Button(L("Restaurar líneas originales")) { perform { reader.visibleInterlinearLines = nil } }
            } label: { MacToolbarLabel(L("Líneas del interlineal"), "text.alignleft") }.help(L("Líneas del interlineal")).menuIndicator(.hidden)
        }
    }
    @ViewBuilder private var versionControls: some View {
        if reader.canSynchronizeBible {
            MacReaderControlGroup {
                icon("Versión anterior", "chevron.left") { workspace.cycleBibleVersion(reader, backwards: true) }.disabled(reader.isLoading)
                ParallelBibleMenu(workspace: workspace, reader: reader)
                icon("Versión siguiente", "chevron.right") { workspace.cycleBibleVersion(reader) }.disabled(reader.isLoading)
            }
        } else {
            MacReaderControlGroup {
                icon("Atrás", "chevron.left", reader.goBack).disabled(!reader.canGoBack)
                icon("Adelante", "chevron.right", reader.goForward).disabled(!reader.canGoForward)
            }
        }
    }
    private var navigationControls: some View { versionControls }
    @ViewBuilder private var graphicsMenu: some View {
        if let assets = reader.page?.graphics, !assets.isEmpty {
            Menu {
                ForEach(Array(assets.filter { !ReaderImageRenderer.isDecoration($0) }.enumerated()), id: \.offset) { index, asset in
                    Button(LF("Abrir imagen {number}", ["number": String(index + 1)])) { perform { if let image = ReaderImageRenderer.decode(asset.data) { MapPreview.show(image: image, title: reader.resource.title) } } }
                }
            } label: { MacToolbarLabel(L("Mapas e imágenes"), "photo") }.help(L("Mapas e imágenes")).menuIndicator(.hidden)
        }
    }
    private func actionsMenu(expanded: Bool) -> some View {
        Menu {
            if expanded {
                bookChapterControls(inMenu: true)
                Menu(L("Versículo")) {
                    ForEach(references, id: \.self) { reference in
                        Button(reference) { perform { reader.changeLocatorMode(false); reader.locator = reference; reader.goToReference() } }
                    }
                }.disabled(references.isEmpty)
                Menu(L("Índice activo")) {
                    Button(L("Referencia bíblica")) { perform { reader.changeLocatorMode(false) } }
                    Button(L("Artículo")) { perform { reader.changeLocatorMode(true) } }
                }
                Divider()
                Button(L("Artículo anterior")) { perform(reader.previousArticle) }.disabled(!reader.canGoToPreviousArticle)
                Button(L("Artículo siguiente")) { perform(reader.nextArticle) }.disabled(!reader.canGoToNextArticle)
                Menu(L("Historial de lectura")) { historyItems }.disabled(reader.history.count < 2)
                Divider()
                Button(L("Contenido")) { perform { reader.showsContents.toggle() } }
                Button(L("Panel localizador")) { perform { reader.showsLocator.toggle() } }
                Toggle(L("Destino de las referencias"), isOn: Binding(
                    get: { workspace.referenceTargetID == reader.id },
                    set: { selected in perform { workspace.setReferenceTarget(selected, for: reader) } }))
                ParallelBibleMenu(workspace: workspace, reader: reader, toolbarPresentation: false)
                Button(L("Recursos asociados…")) { workspace.beginAssociatedResources(source: reader) }
                Button(L("Buscar en este recurso")) { perform(reader.showFind) }
                interlinearMenu
                graphicsMenu
                Divider()
            }
            outputItems
            Divider()
            Button(L("Duplicar lectura")) { workspace.duplicate(reader) }
            Button(L("Propiedades…")) { perform { workspace.activeTool = .information } }
            Button(L("Cerrar lectura")) { workspace.close(reader) }
        } label: { MacToolbarLabel(L("Acciones de lectura"), "ellipsis") }
            .menuIndicator(.hidden).help(L("Acciones de lectura"))
    }
    private var outputItems: some View { ReaderOutputMenuItems(reader: reader, workspace: workspace) }
    @ViewBuilder private var historyItems: some View {
        ForEach(Array(reader.history.indices.reversed()), id: \.self) { index in
            let destination = reader.history[index]
            Button("\(index == reader.historyIndex ? "✓ " : "")\(destination.reference ?? LF("Artículo {number}", ["number": String(destination.ordinal + 1)]))") { perform { reader.selectHistory(index) } }
        }
    }
    private var references: [String] { reader.bibleReferences }
    private var zoomMenu: some View {
        ReaderZoomMenu(reader: reader, activate: { workspace.activate(reader) })
    }
    private var referenceTargetButton: some View {
        let selected = workspace.referenceTargetID == reader.id
        return icon("Destino de las referencias", "scope") { workspace.toggleReferenceTarget(reader) }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .accessibilityValue(L(selected ? "Activado" : "Desactivado"))
            .help(L(selected ? "Destino de las referencias · Activado" : "Destino de las referencias · Desactivado"))
            .transaction { $0.animation = nil }
    }
    private func icon(_ label: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        MacToolbarButton(label, symbol) { perform(action) }
    }
    private func perform(_ action: () -> Void) { workspace.activate(reader); action() }

}

struct BibleSynchronizationMenu: View {
    @Bindable var workspace: StudyWorkspace
    var reader: ReaderSession?
    private var isLinked: Bool { reader.map { $0.linkGroup != .none } ?? false }
    var body: some View {
        Menu {
            Text(L("Sincronizar por versículo"))
            Button(L("Sincronizar todas las Biblias abiertas")) {
                if let reader { workspace.activate(reader) }; workspace.synchronizeBibles(from: reader)
            }.disabled(workspace.bibleReaders.count < 2 || reader?.canSynchronizeBible != true)
            if let reader {
                Divider()
                ForEach(workspace.bibleReaders.filter { $0 !== reader }) { other in
                    Toggle(other.resource.title, isOn: Binding(
                        get: { reader.linkGroup != .none && reader.linkGroup == other.linkGroup },
                        set: { workspace.activate(reader); workspace.setBibleLink($0, from: reader, to: other) }))
                }
                Divider()
                Button(L("Desvincular esta Biblia")) { workspace.activate(reader); workspace.setLinkGroup(.none, for: reader) }.disabled(reader.linkGroup == .none)
            }
            Button(L("Desvincular todas las Biblias"), action: workspace.clearLinks)
                .disabled(!workspace.readers.contains { $0.linkGroup != .none })
        } label: {
            MacToolbarLabel(L("Sincronizar Biblias"), "link").foregroundStyle(isLinked ? Color.accentColor : Color.primary)
        }
        .menuIndicator(.hidden).help(L("Sincronización por versículo · Elegir las Biblias vinculadas"))
        .disabled(reader?.canSynchronizeBible != true && !isLinked)
    }
}
