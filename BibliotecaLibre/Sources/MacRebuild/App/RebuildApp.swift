import AppKit
import SwiftUI
import LibronixCore

typealias RebuildViewState<Value> = SwiftUI.State<Value>

@main struct LibronXRebuildApp: App {
    @NSApplicationDelegateAdaptor(RebuildLifecycle.self) private var lifecycle
    @RebuildViewState private var workspace = StudyWorkspace()
    var body: some Scene {
        Window("Libron-X", id: "study") {
            StudyRootView(workspace: workspace, lifecycle: lifecycle)
                .modifier(AppInterfaceLanguage())
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { RebuildCommands(workspace: workspace) }
        Window(L("Mi biblioteca"), id: "library") {
            LibraryChooser(workspace: workspace).frame(minWidth: 540, minHeight: 420).modifier(AppInterfaceLanguage())
        }.defaultSize(width: 660, height: 560)
        Settings { AppSettingsView(workspace: workspace).modifier(AppInterfaceLanguage()) }
    }
}
@MainActor final class RebuildLifecycle: NSObject, NSApplicationDelegate {
    weak var workspace: StudyWorkspace?
    let startup = WorkspaceStartupCoordinator()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        AppPreferences.shared.applySavedAppearance()
        AppIconPreferences.shared.applySavedSelection()
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
    }
    @objc private func menuTrackingBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu === NSApplication.shared.mainMenu else { return }
        // A menu refresh may disclose a history-file failure in the menu itself;
        // it must not interrupt reading with an unrelated modal alert.
        try? workspace?.recentWorkspaces.refreshPruningMissingFiles()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        do { try startup.save(workspace); return .terminateNow }
        catch {
            let alert = NSAlert()
            alert.messageText = "No se pudo guardar el área de trabajo"
            alert.informativeText = error.localizedDescription + " Puedes cancelar la salida y guardar tus lecturas en otro archivo."
            alert.addButton(withTitle: "Cancelar")
            alert.addButton(withTitle: "Salir sin guardar")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        workspace?.shutdown()
    }
}

struct RebuildCommands: Commands {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("Nuevo archivo de notas")) { workspace.newDocument(.notebook) }.keyboardShortcut("n")
            Button(L("Nueva lista de versículos")) { workspace.newDocument(.verseList) }
            Button(L("Abrir documento…"), action: workspace.openDocument).keyboardShortcut("o")
            Divider()
            Button(L("Mi biblioteca…")) { openWindow(id: "library") }.keyboardShortcut("l")
            Button(L("Abrir carpeta de recursos…"), action: workspace.chooseLibrary).keyboardShortcut("o", modifiers: [.command, .shift])
        }
        // The system save group also owns Close (Command-W). Add workspace
        // commands without removing responder-chain window closing.
        CommandGroup(before: .saveItem) {
            Button(L("Guardar área de trabajo…"), action: workspace.saveWorkspace).keyboardShortcut("s", modifiers: [.command, .shift])
            Button(L("Cargar área de trabajo…"), action: workspace.openWorkspace)
            Menu(L("Áreas de trabajo recientes")) {
                if workspace.recentWorkspaces.loadError != nil {
                    Text(L("No se pudo leer la lista de áreas recientes."))
                }
                if workspace.recentWorkspaces.urls.isEmpty {
                    Text(L("No hay áreas de trabajo recientes."))
                }
                ForEach(workspace.recentWorkspaces.urls, id: \.self) { url in
                    Button { workspace.openRecentWorkspace(url) } label: {
                        Text(workspace.recentWorkspaces.menuTitle(for: url))
                    }.help(url.path)
                }
                Divider()
                Button(L("Vaciar lista"), action: workspace.clearRecentWorkspaces)
                    .disabled(workspace.recentWorkspaces.urls.isEmpty)
            }
        }
        CommandGroup(replacing: .printItem) {
            Button(L("Imprimir lectura…")) { if let reader = workspace.activeReader { ReaderOutputActions.printReader(reader, workspace: workspace) } }
                .keyboardShortcut("p").disabled(workspace.activeReader?.page == nil)
            Menu(L("Exportar lectura")) {
                ForEach(["txt", "rtfd", "html", "pdf"], id: \.self) { type in
                    Button(type.uppercased() + "…") { if let reader = workspace.activeReader { ReaderOutputActions.export(reader, type: type, workspace: workspace) } }
                        .disabled(type == "rtfd" && workspace.activeReader?.page?.oeb != nil)
                }
                if workspace.activeReader?.page?.oeb != nil {
                    Button(L("Archivo web…")) { if let reader = workspace.activeReader { ReaderOutputActions.export(reader, type: "webarchive", workspace: workspace) } }
                }
            }.disabled(workspace.activeReader?.page == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(L("Contenido")) { workspace.activeReader?.showsContents.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(workspace.activeReader == nil)
            Button(L("Panel localizador")) { workspace.activeReader?.showsLocator.toggle() }.disabled(workspace.activeReader == nil)
            Button(L("Propiedades del recurso…")) { workspace.activeTool = .information }.disabled(workspace.activeReader == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(L("Buscar en este recurso…")) { workspace.activeReader?.showFind() }
                .keyboardShortcut("f").disabled(workspace.activeReader?.page == nil)
            Button(L("Buscar siguiente")) { workspace.activeReader?.find(.forward) }
                .keyboardShortcut("g").disabled(workspace.activeReader?.findQuery.isEmpty != false)
            Button(L("Buscar anterior")) { workspace.activeReader?.find(.backward) }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(workspace.activeReader?.findQuery.isEmpty != false)
        }
        CommandMenu(L("Ir")) {
            Button(L("Mi biblioteca…")) { openWindow(id: "library") }
            Button(L("Explorador temático…")) { workspace.activeTool = .topics }.keyboardShortcut("t")
            Button(L("Sincronizar Biblias abiertas")) { workspace.synchronizeBibles() }.disabled(workspace.bibleReaders.count < 2)
            Divider()
            ParallelBibleMenu(workspace: workspace, reader: workspace.activeReader, toolbarPresentation: false)
            Button(L("Versión de Biblia anterior")) {
                if let reader = workspace.activeReader { workspace.cycleBibleVersion(reader, backwards: true) }
            }.disabled(workspace.activeReader?.canSynchronizeBible != true || workspace.activeReader?.isLoading == true)
            Button(L("Versión de Biblia siguiente")) {
                if let reader = workspace.activeReader { workspace.cycleBibleVersion(reader) }
            }.disabled(workspace.activeReader?.canSynchronizeBible != true || workspace.activeReader?.isLoading == true)
            Divider()
            Button(L("Artículo anterior")) { workspace.activeReader?.previousArticle() }.disabled(workspace.activeReader?.canGoToPreviousArticle != true)
            Button(L("Artículo siguiente")) { workspace.activeReader?.nextArticle() }.disabled(workspace.activeReader?.canGoToNextArticle != true)
            Divider()
            Button(L("Atrás")) { workspace.activeReader?.goBack() }.keyboardShortcut("[", modifiers: [.command])
                .disabled(workspace.activeReader?.canGoBack != true)
            Button(L("Adelante")) { workspace.activeReader?.goForward() }.keyboardShortcut("]", modifiers: [.command])
                .disabled(workspace.activeReader?.canGoForward != true)
        }
        CommandMenu(L("Buscar")) {
            Button(L("Búsqueda básica…"), action: workspace.beginSearch).keyboardShortcut("f", modifiers: [.command, .shift])
            Button(L("Búsqueda bíblica…")) { workspace.search.bibleVerses = true; workspace.beginSearch() }
            Button(L("Explorador temático…")) { workspace.activeTool = .topics }
        }
        CommandMenu(L("Favoritos")) {
            Button(L("Agregar ubicación actual"), action: workspace.addFavorite).disabled(workspace.activeReader?.page == nil)
            Button(L("Organizar favoritos…")) { workspace.activeTool = .favorites }
        }
        CommandMenu(L("Herramientas")) {
            Button(L("Copiar versículos bíblicos…")) { workspace.activeTool = .bibleCopy }
            Button(L("Documentos de estudio…")) { workspace.activeTool = .documents }
            Button(L("Recursos y licencias…")) { workspace.activeTool = .resources }
        }
        CommandGroup(before: .windowArrangement) {
            Button(L("Duplicar lectura")) { if let reader = workspace.activeReader { workspace.duplicate(reader) } }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(workspace.activeReader?.page == nil)
            Button(L("Siguiente lectura")) { workspace.cycleReader() }.keyboardShortcut("`", modifiers: [.command, .option]).disabled(workspace.readers.count < 2)
            Button(L("Lectura anterior")) { workspace.cycleReader(backwards: true) }
                .keyboardShortcut("`", modifiers: [.command, .option, .shift]).disabled(workspace.readers.count < 2)
            Toggle(L("Destino de las referencias"), isOn: Binding(
                get: { workspace.activeReader.map { workspace.referenceTargetID == $0.id } ?? false },
                set: { value in if let reader = workspace.activeReader { workspace.setReferenceTarget(value, for: reader) } }))
                .disabled(workspace.activeReader == nil)
            Menu(L("Vínculos")) {
                ForEach(ReaderLinkGroup.allCases, id: \.self) { group in
                    Toggle(group == .none ? L("Sin vínculos") : LF("Grupo {group}", ["group": group.rawValue]), isOn: Binding(
                        get: { workspace.activeReader?.linkGroup == group },
                        set: { workspace.setActiveLinkGroup(group, selected: $0) }))
                }
            }.disabled(!workspace.canLinkActiveReader)
            Button(L("Borrar todos los vínculos"), action: workspace.clearLinks)
                .disabled(!workspace.readers.contains { $0.linkGroup != .none })
            Button(L("Cerrar panel")) { if let reader = workspace.activeReader { workspace.close(reader) } }
                // Option-Command-W belongs to the restored native Close All command.
                .keyboardShortcut("w", modifiers: [.command, .control]).disabled(workspace.activeReader == nil)
            Button(L("Cerrar todos los paneles"), action: workspace.closeAll).disabled(workspace.readers.isEmpty)
            Divider()
            Button(L("Cascada")) { workspace.arrange(.cascade) }.disabled(workspace.visibleReaders.isEmpty)
            Button(L("Mosaico horizontal")) { workspace.arrange(.horizontal) }.disabled(workspace.visibleReaders.isEmpty)
            Button(L("Mosaico vertical")) { workspace.arrange(.vertical) }.disabled(workspace.visibleReaders.isEmpty)
            Divider()
            ForEach(workspace.orderedReaders) { reader in
                Button((workspace.activeID == reader.id ? "✓ " : "") + reader.resource.title) { workspace.activate(reader) }
            }
            Button(L("Ventanas…")) { workspace.activeTool = .windows }.disabled(workspace.readers.isEmpty)
            Divider()
        }
    }
}
