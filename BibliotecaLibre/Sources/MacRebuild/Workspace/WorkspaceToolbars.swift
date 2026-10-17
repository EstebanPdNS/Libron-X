import SwiftUI
import LibronixCore

struct MainWorkspaceToolbar: ToolbarContent {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.openWindow) private var openWindow
    @ToolbarContentBuilder var body: some ToolbarContent {
        leadingItems
        ToolbarItemGroup {
            Menu {
                Button(L("Archivo de notas")) { workspace.newDocument(.notebook) }
                Button(L("Lista de versículos")) { workspace.newDocument(.verseList) }
            } label: { MacToolbarMenuLabel(L("Nuevo documento"), "square.and.pencil") }
                .help(L("Nuevo documento"))
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
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        ToolbarItemGroup {
            ReaderZoomMenu(reader: workspace.activeReader)
            ReaderMarkupMenu(workspace: workspace)
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
            MacToolbarButton(L("Diccionarios"), "character.book.closed") { workspace.dictionary.openInside(workspace: workspace) }
            MacToolbarButton(L("Buscar actualizaciones"), "arrow.down.circle") { AppUpdater.shared.check() }
            MacToolbarButton(L("Administrar recursos y licencias"), "lock.open") { workspace.activeTool = .resources }
            MacToolbarButton(L("Propiedades del recurso"), "info.circle") { workspace.activeTool = .information }
                .disabled(workspace.activeReader == nil)
        }
        if workspace.isImporting {
            ToolbarItem(placement: .status) {
                HStack { ProgressView().controlSize(.small); Text(workspace.importProgress).font(.caption) }
            }
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
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
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
            // A discrete native Slider draws 301 tick marks below its track.
            // Keep the track continuous and round the bound percentage instead.
            Slider(value: Binding(get: { reader.textScale * 100 }, set: { reader.textScale = $0.rounded() / 100 }), in: 0...300)
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
    var body: some View {
        Menu {
            Button(L("Resaltar en amarillo")) { workspace.addHighlight("yellow") }
            Button(L("Resaltar en verde")) { workspace.addHighlight("green") }
            Button(L("Resaltar en azul")) { workspace.addHighlight("blue") }
            Button(L("Resaltar en rosa")) { workspace.addHighlight("pink") }
            Divider()
            Button(L("Borrar marcación seleccionada"), action: workspace.eraseHighlight)
        } label: { MacToolbarLabel(L("Marcación visual"), "highlighter") }
            .help(L("Marcación visual")).menuIndicator(.hidden)
            .disabled((workspace.activeReader?.selectedRange.length ?? 0) == 0)
    }
}

struct ResourceReaderToolbar: View {
    @Bindable var reader: ReaderSession
    @Bindable var workspace: StudyWorkspace
    @Environment(\.openWindow) private var openWindow
    @FocusState private var referenceFocused: Bool
    var body: some View {
        MacReaderToolbarSurface {
            ViewThatFits(in: .horizontal) {
                fullControls.fixedSize(horizontal: true, vertical: false)
                compactControls
                minimalControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).frame(height: 44)
        .background(.bar)
        .transaction { $0.animation = nil }
        .onChange(of: referenceFocused) { if referenceFocused { workspace.activate(reader) } }
    }
    private var fullControls: some View {
        HStack(spacing: 8) {
            referenceField.frame(width: 180)
            MacReaderControlGroup {
                icon("Ir a la referencia", "arrow.right", reader.goToReference)
                referenceMenu
                locatorMenu
            }
            MacReaderControlGroup {
                referenceTargetButton
                ParallelBibleMenu(workspace: workspace, reader: reader)
            }
            MacReaderControlGroup {
                icon("Artículo anterior", "chevron.up", reader.previousArticle).disabled(!reader.canGoToPreviousArticle)
                icon("Artículo siguiente", "chevron.down", reader.nextArticle).disabled(!reader.canGoToNextArticle)
            }
            navigationControls
            MacReaderControlGroup {
                icon("Contenido", "sidebar.left") { reader.showsContents.toggle() }
                icon("Panel localizador", "rectangle.topthird.inset.filled") { reader.showsLocator.toggle() }
                interlinearMenu
            }
            MacReaderControlGroup {
                icon("Buscar en este recurso", "magnifyingglass") { reader.showFind() }
                zoomMenu
                graphicsMenu
                actionsMenu(expanded: false)
            }
        }
    }
    private var compactControls: some View {
        HStack(spacing: 8) {
            referenceField.frame(minWidth: 100, idealWidth: 160, maxWidth: .infinity)
            MacReaderControlGroup {
                icon("Ir a la referencia", "arrow.right", reader.goToReference)
                icon("Atrás", "chevron.left", reader.goBack).disabled(!reader.canGoBack)
                icon("Adelante", "chevron.right", reader.goForward).disabled(!reader.canGoForward)
            }
            MacReaderControlGroup {
                referenceTargetButton
                icon("Contenido", "sidebar.left") { reader.showsContents.toggle() }
                icon("Buscar en este recurso", "magnifyingglass") { reader.showFind() }
                zoomMenu
                actionsMenu(expanded: true)
            }
        }
    }
    private var minimalControls: some View {
        HStack(spacing: 6) {
            referenceField.frame(minWidth: 40, maxWidth: .infinity)
            MacReaderControlGroup {
                zoomMenu
                actionsMenu(expanded: true)
            }
        }
    }
    private var referenceField: some View {
        TextField(L(reader.locatorIsArticle ? "Artículo" : "Referencia"), text: $reader.locator)
            .onSubmit { workspace.activate(reader); reader.goToReference() }
            .focused($referenceFocused)
            .macInputStyle()
            .help(reader.locatorIsArticle ? L("Número de artículo") : "Génesis 4:1 · Gen 4.1 · Gn 4,1 · Génesis 4")
            .environment(\.layoutDirection, .leftToRight)
    }
    private var referenceMenu: some View {
        Menu {
            ForEach(references, id: \.self) { reference in
                Button(reference) { perform { reader.changeLocatorMode(false); reader.locator = reference; reader.goToReference() } }
            }
        } label: { MacToolbarLabel(L("Ubicaciones de referencia"), "list.bullet") }
            .menuIndicator(.hidden).help(L("Ubicaciones de referencia")).disabled(references.isEmpty)
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
    private var navigationControls: some View {
        MacReaderControlGroup {
            icon("Atrás", "chevron.left", reader.goBack).disabled(!reader.canGoBack)
            icon("Adelante", "chevron.right", reader.goForward).disabled(!reader.canGoForward)
            Menu { historyItems } label: { MacToolbarLabel(L("Historial de lectura"), "clock.arrow.circlepath") }
                .menuIndicator(.hidden).help(L("Historial de lectura")).disabled(reader.history.count < 2)
        }
    }
    @ViewBuilder private var graphicsMenu: some View {
        if let assets = reader.page?.graphics, !assets.isEmpty {
            Menu {
                ForEach(Array(assets.enumerated()), id: \.offset) { index, asset in
                    Button(LF("Abrir imagen {number}", ["number": String(index + 1)])) { perform { if let image = ReaderImageRenderer.decode(asset.data) { MapPreview.show(image: image, title: reader.resource.title) } } }
                }
            } label: { MacToolbarLabel(L("Mapas e imágenes"), "photo") }.help(L("Mapas e imágenes")).menuIndicator(.hidden)
        }
    }
    private func actionsMenu(expanded: Bool) -> some View {
        Menu {
            if expanded {
                Button(L("Ir a la referencia")) { perform(reader.goToReference) }
                Menu(L("Ubicaciones de referencia")) {
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
                ParallelBibleMenu(workspace: workspace, reader: reader)
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
    @ViewBuilder private var outputItems: some View {
        Button(L("Copiar selección o artículo")) { workspace.activate(reader); ReaderOutputActions.copy(reader, workspace: workspace) }
        Button(L("Agregar a favoritos")) { workspace.activate(reader); workspace.addFavorite() }
        Button(L("Agregar nota sobre la selección")) { perform { workspace.addNoteForSelection(reader) } }
        Divider()
        Menu(L("Exportar")) {
            Button(L("Texto…")) { perform { ReaderOutputActions.export(reader, type: "txt", workspace: workspace) } }
            Button(L("Texto con imágenes (RTFD)…")) { perform { ReaderOutputActions.export(reader, type: "rtfd", workspace: workspace) } }.disabled(reader.page?.oeb != nil)
            Button(L("HTML…")) { perform { ReaderOutputActions.export(reader, type: "html", workspace: workspace) } }
            Button(L("PDF…")) { perform { ReaderOutputActions.export(reader, type: "pdf", workspace: workspace) } }
            if reader.page?.oeb != nil { Button(L("Archivo web…")) { perform { ReaderOutputActions.export(reader, type: "webarchive", workspace: workspace) } } }
        }
        Button(L("Imprimir…")) { perform { ReaderOutputActions.printReader(reader, workspace: workspace) } }
    }
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
