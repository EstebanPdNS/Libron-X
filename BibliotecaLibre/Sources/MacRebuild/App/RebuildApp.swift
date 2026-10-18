import AppKit
import SwiftUI
import LibronixCore

typealias RebuildViewState<Value> = SwiftUI.State<Value>

struct LibronXRebuildApp: App {
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
            LibraryChooser(workspace: workspace).frame(minWidth: 820, minHeight: 520).modifier(AppInterfaceLanguage())
        }.defaultSize(width: 1160, height: 780)
        Settings { AppSettingsView(workspace: workspace).modifier(AppInterfaceLanguage()) }
    }
}
@MainActor final class RebuildLifecycle: NSObject, NSApplicationDelegate {
    weak var workspace: StudyWorkspace?
    let startup = WorkspaceStartupCoordinator()
    private var canInstallUpdate = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        AppPreferences.shared.applySavedAppearance()
        AppIconPreferences.shared.applySavedSelection()
        AppUpdater.shared.startMonitoring()
        FeatureHelp.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
    }
    @objc private func menuTrackingBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu === NSApplication.shared.mainMenu else { return }
        // A menu refresh may disclose a history-file failure in the menu itself;
        // it must not interrupt reading with an unrelated modal alert.
        try? workspace?.recentWorkspaces.refreshPruningMissingFiles()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        canInstallUpdate = false
        guard let workspace else { return .terminateNow }
        do { try startup.save(workspace); try workspace.personal.save(); canInstallUpdate = true; return .terminateNow }
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
        if canInstallUpdate { AppUpdater.shared.willTerminate() }
        FeatureHelp.shared.stop()
        workspace?.shutdown()
    }
}

struct RebuildCommands: Commands {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("Buscar actualizaciones…")) { AppUpdater.shared.check() }
        }
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
            Button(L("Buscar referencias bíblicas…")) { workspace.beginReferenceSearch() }
            Button(L("Explorador temático…")) { workspace.activeTool = .topics }
        }
        CommandMenu(L("Favoritos")) {
            Button(L("Agregar ubicación actual"), action: workspace.addFavorite).disabled(workspace.activeReader?.page == nil)
            Button(L("Organizar favoritos…")) { workspace.activeTool = .favorites }
        }
        CommandMenu(L("Herramientas")) {
            Button(L("Enlaces clave…")) { workspace.activeTool = .keyLinks }
            Button(L("Diccionarios")) { workspace.dictionary.openInside(workspace: workspace) }
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

/// The installed reader and the reproducible converter share the same code.
@main enum LibronXEntryPoint {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--normalize-library"), args.indices.contains(flag+1) else {
            LibronXRebuildApp.main(); return
        }
        var reports: [LibronNormalizationReceipt] = []
        var failures: [String] = []
        do {
            let root = URL(fileURLWithPath:args[flag+1])
            if let importing = args.firstIndex(of:"--import-directory"), args.indices.contains(importing+1) {
                let folder = URL(fileURLWithPath:args[importing+1])
                let files = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { LibronPackage.sourceExtensions.contains($0.pathExtension.lowercased()) || $0.pathExtension.lowercased() == "libron" }
                var supported: [URL] = []
                for file in files {
                    do { if ESwordResource.extensions.contains(file.pathExtension.lowercased()) { _ = try ESwordResource.inspect(file) }; supported.append(file) }
                    catch { failures.append(file.lastPathComponent+": "+error.localizedDescription); print("Import pending: "+file.lastPathComponent+": "+error.localizedDescription) }
                }
                print("Importing \(supported.count) supported files")
                _ = try await LibronLibrary().convert(supported,to:root,backup:false)
            }
            var resources = try await LibraryImporter().importDirectory(at:root).resources
            if !args.contains("--resource") { try LibronCatalog(resources:resources).save(to:root) }
            if let only = args.firstIndex(of:"--resource"), args.indices.contains(only+1) {
                resources = resources.filter { $0.fileName.caseInsensitiveCompare(args[only+1]) == .orderedSame || $0.location.lastPathComponent.caseInsensitiveCompare(args[only+1]) == .orderedSame }
                guard !resources.isEmpty else { throw LibronError.invalid("Requested resource not found") }
            }
            for var resource in resources {
                do {
                    if (args.contains("--refresh-metadata") || args.contains("--refresh-metadata-only")), resource.format == .eSwordSQLite, let package = resource.packageLocation {
                        var manifest = try LibronPackage.read(package).0
                        let declared = LibronBibliography.enrich(try ESwordResource.inspect(resource.location))
                        var metadata = manifest.metadata
                        var changed: Set<String> = []
                        if metadata.authors.isEmpty, !declared.authors.isEmpty { metadata.authors = declared.authors; changed.insert("authors") }
                        if metadata.publisher == nil, let value = declared.publisher { metadata.publisher = value; changed.insert("publisher") }
                        if metadata.year == nil, let value = declared.year { metadata.year = value; changed.insert("year") }
                        if metadata.edition == nil, let value = declared.edition { metadata.edition = value; changed.insert("edition") }
                        if metadata.languages.isEmpty, !declared.languages.isEmpty { metadata.languages = declared.languages; changed.insert("languages") }
                        metadata.evidence += declared.evidence.filter { changed.contains($0.field) }
                        metadata.pendingFields.removeAll { changed.contains($0) }
                        if metadata != manifest.metadata {
                            manifest.metadata = metadata
                            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                            try encoder.encode(manifest).write(to:package.appendingPathComponent("manifest.json"),options:.atomic)
                            resource = try LibronPackage.read(package).1
                        }
                    }
                    if args.contains("--refresh-metadata-only") { continue }
                    if let receipt = try await LibronNativeNormalizer.shared.convert(resource,progress:{ current,total in
                        if current % 1000 == 0 || current == total { print("Sections: \(current)/\(total)") }
                    }) {
                        reports.append(receipt)
                        print("Converted: \(resource.title) [\(receipt.checkedSections) sections]")
                    }
                } catch { failures.append(resource.title+": "+error.localizedDescription);print("Pending: \(resource.title): \(error.localizedDescription)") }
            }
            if args.contains("--organize-library") {
                var plan: [(URL,URL,String)] = []
                for resource in resources {
                    guard let package = resource.packageLocation else { continue }
                    let manifest = try LibronPackage.read(package).0
                    let destination = root.appendingPathComponent(LibronPackage.filename(manifest.metadata,hash:manifest.payload.sha256))
                    if package.standardizedFileURL != destination.standardizedFileURL {
                        if FileManager.default.fileExists(atPath:destination.path) {
                            // APFS can return a decomposed spelling for the same
                            // Unicode filename; compare package identity first.
                            if try LibronPackage.read(destination).0.id == manifest.id { continue }
                            throw LibronError.invalid("Organized package name collision")
                        }
                        plan.append((package,destination,manifest.metadata.title))
                    }
                }
                var moved: [(URL,URL)] = []
                do {
                    for (package,destination,title) in plan {
                        try FileManager.default.moveItem(at:package,to:destination)
                        moved.append((package,destination));print("Organized: \(title)")
                    }
                } catch {
                    for (original,destination) in moved.reversed() { try? FileManager.default.moveItem(at:destination,to:original) }
                    throw error
                }
            }
            if !args.contains("--resource") {
                let current = try await LibraryImporter().importDirectory(at:root).resources
                try LibronCatalog(resources:current).save(to:root)
                let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                if !args.contains("--refresh-metadata-only") {
                    try encoder.encode(reports).write(to:root.appendingPathComponent("normalization-report.json"),options:.atomic)
                    try encoder.encode(failures).write(to:root.appendingPathComponent("normalization-pending.json"),options:.atomic)
                }
            }
            print("Normalization finished: \(reports.count) converted; \(failures.count) pending")
            exit(failures.isEmpty ? 0 : 1)
        } catch { print("Normalization failed: \(error.localizedDescription)");exit(1) }
    }
}
