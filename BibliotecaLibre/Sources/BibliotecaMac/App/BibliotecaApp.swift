import AppKit
import LibronixCore
import SwiftUI

// Disambiguate the established property wrapper from the newer SDK macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main struct LibronXApp: App {
    private let library: LibraryStore = {
        let arguments = CommandLine.arguments
        let offset = arguments.firstIndex(of: "--personal-directory")
        let directory = offset.flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        return LibraryStore(personalDirectory: directory)
    }()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Libron-X") {
            LibraryWindowRoot(store: library)
        }
        .defaultSize(width: 1380, height: 880)
        .windowToolbarStyle(.unifiedCompact)
        .commands { LibronXCommands(store: library) }
        WindowGroup("Recurso · Libron-X", id: "resource", for: String.self) { resourceID in
            LibraryWindowRoot(store: library, initialResourceID: resourceID.wrappedValue)
        }
        .defaultSize(width: 1380, height: 880)
        .windowToolbarStyle(.unifiedCompact)
        Settings { LibrarySettings() }
        WindowGroup("Espacio de trabajo · Libron-X", id: "workspace", for: String.self) { key in
            LibraryWindowRoot(store: library, workspaceKey: key.wrappedValue)
        }
        .defaultSize(width: 1380, height: 880)
        .windowToolbarStyle(.unifiedCompact)
    }
}

struct LibraryWindowRoot: View {
    let store: LibraryStore
    @ViewState private var model: LibraryModel
    @AppStorage("appearance.v1") private var appearance = "system"
    init(store: LibraryStore, initialResourceID: String? = nil, workspaceKey: String? = nil) {
        self.store = store
        let model = LibraryModel(store: store)
        model.selection = initialResourceID
        if initialResourceID != nil { model.reader.tab = .preview }
        if let state = store.takePendingWindow(workspaceKey) { model.restore(state) }
        _model = State(initialValue: model)
    }
    var body: some View {
        LibraryWorkspace(model: model)
            .frame(minWidth: 980, minHeight: 640)
            .focusedSceneValue(\.libraryModel, model)
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
            .task { store.restoreLibraryIfAvailable(); model.reconcileSelection() }
            .onChange(of: store.snapshot?.resources.map(\.id)) { _, _ in model.reconcileSelection() }
            .onDisappear { model.reader.cancelPendingRead(); model.bookSearch.cancel(); model.cancelOriginalNavigation(); model.output.cancelPreparation(); model.bibleCopy.invalidate(); store.documents.flush(); store.unregister(model) }
    }
}

private struct LibraryModelFocusKey: FocusedValueKey { typealias Value = LibraryModel }
extension FocusedValues {
    var libraryModel: LibraryModel? {
        get { self[LibraryModelFocusKey.self] }
        set { self[LibraryModelFocusKey.self] = newValue }
    }
}

struct LibronXCommands: Commands {
    let store: LibraryStore
    @FocusedValue(\.libraryModel) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        SidebarCommands()
        TextFormattingCommands()
        CommandMenu("Herramientas") {
            Button("Copiar versículos bíblicos…") { model?.openBibleCopy() }
                .disabled(model?.resources.contains(where:{$0.format == .legacyLSF && !$0.isHelp}) != true)
        }
        CommandGroup(replacing:.printItem) {
            Button("Configurar página…") { model?.output.showsPageSetup = true }.disabled(model?.canPrepareOutput != true)
            Button("Vista previa de impresión") { model?.prepareOutput(.preview) }.disabled(model?.canPrepareOutput != true)
            Button("Imprimir…") { model?.prepareOutput(.printReading) }.keyboardShortcut("p",modifiers:[.command]).disabled(model?.canPrepareOutput != true)
            Button("Exportar…") { model?.prepareOutput(.export) }.disabled(model?.canPrepareOutput != true)
            Divider()
            Button("Imprimir selección…") { model?.prepareOutput(.printSelection) }
                .disabled(model?.canPrepareOutput != true || (model?.reader.selectedTextRange?.length ?? 0) == 0)
        }
        CommandGroup(after: .newItem) {
            Button("Abrir biblioteca…", action: store.chooseLibrary)
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Abrir recurso en nueva ventana") {
                guard let model, model.selectedResource != nil else { return }
                var state = model.workspaceState(); state.linkGroup = .none
                openWindow(id: "workspace", value: store.enqueueWindow(state))
            }.disabled(model?.selectedResource == nil)
            Button("Actualizar catálogo", action: store.reload)
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(store.snapshot == nil || store.isImporting)
            Divider()
            Button("Guardar espacio de trabajo…", action: store.saveWorkspace)
                .keyboardShortcut("s", modifiers: [.command, .option]).disabled(store.snapshot == nil)
            Button("Abrir espacio de trabajo…") { store.loadWorkspace { openWindow(id: "workspace", value: $0) } }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }
        CommandGroup(after: .textEditing) {
            Button("Buscar en el catálogo") { model?.searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Buscar en el artículo") { model?.reader.findFocusRequest += 1; model?.reader.tab = .preview }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(model?.reader.content == nil)
        }
        CommandMenu("Biblioteca") {
            Button("Todos los recursos") { model?.section = .all }.keyboardShortcut("1", modifiers: [.command])
            Button("Títulos recuperados") { model?.section = .recovered }.keyboardShortcut("2", modifiers: [.command])
            Button("Colecciones y estilos") { model?.section = .collections }.keyboardShortcut("3", modifiers: [.command])
        }
        CommandMenu("Buscar") {
            Button("Buscar en libros…") { model?.section = .search; model?.bookSearch.focusRequest += 1 }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        readingCommands
    }
    // Keep each command builder within Xcode 26's ten-element overloads.
    @CommandsBuilder private var readingCommands: some Commands {
        CommandMenu("Lectura") {
            Button("Atrás") { model?.reader.goBack() }.keyboardShortcut("[", modifiers: [.command])
                .disabled(model?.reader.canGoBack != true)
            Button("Adelante") { model?.reader.goForward() }.keyboardShortcut("]", modifiers: [.command])
                .disabled(model?.reader.canGoForward != true)
            Divider()
            Button("Artículo anterior") { model?.reader.load((model?.reader.ordinal ?? 0) - 1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(model?.reader.ordinal == 0)
            Button("Artículo siguiente") { model?.reader.load((model?.reader.ordinal ?? 0) + 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(model?.reader.content == nil)
            Button("Ir a un pasaje…") { model?.reader.locatorFocusRequest += 1; model?.reader.tab = .preview }
                .keyboardShortcut("l", modifiers: [.command]).disabled(model?.selectedResource?.format != .legacyLSF)
        }
        CommandMenu("Favoritos") {
            Button("Organizar favoritos y marcadores") { model?.section = .favorites }
            Button("Guardar lectura como favorito") {
                guard let model, let location = model.reader.currentLocation else { return }
                store.personal.change { try $0.insert(LibraryFavorite(title: model.reader.currentTitle, kind: .location, location: location)) }
            }.keyboardShortcut("d", modifiers: [.command]).disabled(model?.reader.currentLocation == nil)
            Divider()
            ForEach(1...9, id: \.self) { slot in
                Button("Ir al marcador \(slot)") { if let location = store.personal.bookmarks.slots[slot] { model?.navigate(location) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(slot))), modifiers: [.control])
                    .disabled(store.personal.bookmarks.slots[slot] == nil)
            }
            Menu("Asignar marcador") {
                ForEach(1...9, id: \.self) { slot in
                    Button("Marcador \(slot)") { store.personal.setBookmark(slot, location: model?.reader.currentLocation) }
                        .disabled(model?.reader.currentLocation == nil)
                }
            }
        }
        CommandMenu("Vínculos") {
            ForEach(ReaderLinkGroup.allCases, id: \.self) { group in
                Button(group.title) { model?.linkGroup = group }.disabled(model?.selectedResource == nil)
            }
            Divider()
            Button("Quitar todos los vínculos", action: store.clearLinks)
        }
        CommandMenu("Documentos") {
            Button("Mostrar documentos de estudio") { model?.section = .documents }
            Button("Nuevo archivo de notas") { model?.selectedDocumentID = store.documents.create(kind: .notebook, title: "Mis notas"); model?.section = .documents }
            Button("Nueva lista de versículos") { model?.selectedDocumentID = store.documents.create(kind: .verseList, title: "Mis versículos"); model?.section = .documents }
            Button("Importar documento…") { store.documents.importDocument { model?.selectedDocumentID = $0; model?.section = .documents } }
            Divider()
            Button("Añadir nota a la lectura") { model?.addStudyNote(selection: false) }.disabled(model?.reader.currentLocation == nil)
            Button("Añadir nota a la selección") { model?.addStudyNote(selection: true) }.disabled((model?.reader.selectedTextRange?.length ?? 0) == 0)
        }
    }
}

struct BrandMark: View {
    private var emblem: NSImage? {
        Bundle.main.url(forResource: "Libron-X-emblem-red-1024", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
    var body: some View {
        if let emblem { Image(nsImage: emblem).resizable().scaledToFit().accessibilityHidden(true) }
        else { Image(systemName: "book.closed.fill").resizable().scaledToFit().foregroundStyle(LibraryPalette.brand) }
    }
}

struct LibrarySettings: View {
    private var appVersion:String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.5.0" }
    @AppStorage("readerFontSize.v1") private var fontSize = 18.0
    @AppStorage("readerFontFamily.v1") private var fontFamily = "serif"
    @AppStorage("appearance.v1") private var appearance = "system"
    var body: some View {
        Form {
            HStack(spacing: 14) {
                BrandMark().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text("Libron-X").font(.title2.weight(.semibold))
                    Text("Digital Library System").foregroundStyle(.secondary)
                }
            }.padding(.bottom, 12)
            Picker("Apariencia", selection: $appearance) {
                Text("Automática").tag("system"); Text("Clara").tag("light"); Text("Oscura").tag("dark")
            }
            Picker("Fuente del lector", selection: $fontFamily) {
                Text("Serif").tag("serif"); Text("Sistema").tag("system")
            }
            HStack {
                Text("Tamaño del texto"); Slider(value: $fontSize, in: 12...32, step: 1)
                Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 45)
            }
            Text("Tus recursos se leen desde la carpeta que seleccionas. Los marcadores y posiciones de lectura se guardan en las preferencias de Libron-X.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Versión de desarrollo \(appVersion) · macOS 14 o posterior").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 480)
    }
}
