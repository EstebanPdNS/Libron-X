import AppKit
import SwiftUI

/// In-process accessibility labels identify controls without reading book text,
/// requesting Accessibility permission or changing their normal mouse actions.
enum FeatureHelpTopic: String, CaseIterable, Sendable {
    case toolbar, bibleReading, referenceTarget, imports, dictionary, workspace, language, startup, appearance, reading, hoverNotes, directory, library, groups
    case updates, changelog, information, search, topics, bibleCopy, synchronization, navigation, marks, documents, favorites, maps, output
    var title: String {
        switch self {
        case .toolbar: "Barra de herramientas"
        case .bibleReading: "Lectura bíblica"
        case .referenceTarget: "Destino de las referencias"
        case .imports: "Importar recursos"
        case .dictionary: "Diccionarios"
        case .workspace: "Organizar ventanas"
        case .language: "Idioma de la interfaz"
        case .startup: "Al abrir Libron-X"
        case .appearance: "Apariencia"
        case .reading: "Texto de los recursos"
        case .hoverNotes: "Notas y referencias"
        case .directory: "Abrir directorio"
        case .library: "Biblioteca"
        case .groups: "Grupos"
        case .updates: "Actualizaciones"
        case .changelog: "Cambios de esta versión"
        case .information: "Información"
        case .search: "Buscar"
        case .topics: "Explorador temático"
        case .bibleCopy: "Copiar versículos bíblicos"
        case .synchronization: "Sincronizar Biblias"
        case .navigation: "Acciones de lectura"
        case .marks: "Marcación visual"
        case .documents: "Nuevo documento"
        case .favorites: "Favoritos"
        case .maps: "Mapas e imágenes"
        case .output: "Exportar"
        }
    }
    private static let detailKeys: [String: String] = {
        guard let url = AppStrings.resourceBundle.url(forResource: "HelpTopics", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return keys
    }()
    var paragraphs: [String] {
        let keys: [String] = switch self {
        case .toolbar: ["La barra de herramientas permite abrir Inicio y Biblioteca, buscar, crear documentos y acceder a las acciones de estudio. Los botones que no caben aparecen en el menú de desbordamiento. Haz clic derecho sobre un botón para conocer su función."]
        case .bibleReading: ["Esta ventana muestra una Biblia. Escribe una referencia y pulsa Intro, o elige libro y capítulo. Las flechas junto al icono de Biblia cambian de versión conservando el versículo; el icono permite elegir una Biblia o cambiar de grupo. Usa el zoom para ajustar el texto y el menú de acciones para las demás herramientas."]
        case .referenceTarget: ["Activa este botón para que esta lectura reciba las referencias abiertas desde otros recursos. El botón resaltado identifica la ventana de destino. Vuelve a pulsarlo para desactivarlo; la sincronización de Biblias se configura por separado."]
        case .language: ["El idioma cambia la interfaz. Los libros conservan su texto original.", "Los menús del sistema adoptan el idioma al volver a abrir la aplicación."]
        case .navigation: ["Escribe una referencia como Génesis 4:1, Gen 4.1 o Gn 4,1. También puedes escribir solo el libro y capítulo.", "help.navigation"]
        case .dictionary: ["Selecciona una palabra y elige Buscar en diccionario con el clic derecho. Cambia de diccionario en el selector. Mantén la ventana de diccionarios abierta para consultar automáticamente nuevas palabras; las frases no se consultan."]
        case .imports: ["Selecciona archivos o agrega una carpeta. Se crearán paquetes .libron con metadatos y contenido. Elige Sí para copiar los originales a backup o No para omitir esa copia. Puedes volver a activar la pregunta en Biblioteca."]
        case .reading: ["Elige una fuente instalada en el sistema o conserva la opción predeterminada para respetar los estilos originales. Times New Roman es la fuente de reserva.", "Se aplica a las nuevas lecturas. El 100 % conserva el tamaño de lectura ampliado; los estilos del archivo original no se modifican.", "help.reading"]
        case .hoverNotes: ["help.notes", "También puedes abrirlas haciendo clic en su llamada."]
        case .groups: ["Elige las Biblias y su orden. Las flechas recorren el grupo elegido en cada lectura y conservan el versículo.", "Los cambios de orden se guardan al instante. Quitar un recurso del grupo no borra su archivo."]
        case .library: ["Elige las columnas que deseas ver, ordena por título, autor o idioma y usa Grupo para limitar la lista. Busca español para encontrar recursos en ese idioma.", "Los recursos ocultos no aparecen en Mi biblioteca ni en nuevas búsquedas, el explorador temático o Copiar versículos. Sus archivos se conservan. Las lecturas abiertas y tus documentos siguen disponibles.", "help.directory"]
        case .updates: ["Stable recibe versiones estables. Beta incluye también versiones de prueba.", "Tus lecturas se guardan antes de instalar. La versión anterior se conserva como copia de seguridad.", "help.updates"]
        case .information: ["Biblioteca de estudio bíblico con lecturas en paralelo, búsqueda y documentos personales.", "Número interno para distinguir revisiones de la misma versión."]
        default: ["help." + rawValue]
        }
        return keys.map { Self.detailKeys[$0] ?? $0 }
    }
    static func resolve(labels: [String], windowTitle: String, language: AppLanguage) -> Self {
        let keys = labels.compactMap { label in
            AppStrings.catalog.first { _, values in values[language.rawValue] == label }?.key
        }
        for key in keys {
            let name = key.lowercased()
            if name.contains("destino de las referencias") || name.contains("enfocar") { return .referenceTarget }
            if name.contains("barra de herramientas") { return .toolbar }
            if name.contains("versión anterior") || name.contains("versión siguiente") || name.contains("recursos paralelos") { return .groups }
            if name.contains("propiedades") || name.contains("administrar recursos") { return .library }
            if name.contains("panel localizador") || name.contains("duplicar lectura") { return .navigation }
            if name.contains("diccionario") { return .dictionary }
            if name.contains("importar") || name.contains("convertir") || name.contains("backup") { return .imports }
            if name.contains("fuente") { return .reading }
            if name.contains("idioma") { return .language }
            if name.contains("directorio") || name.contains("carpeta") { return .directory }
            if name.contains("hover") || name.contains("puntero") || name.contains("notas y referencias") { return .hoverNotes }
            if name.contains("tamaño") || name.contains("zoom del texto") || name.contains("lecturas abiertas") { return .reading }
            if name.contains("icono") || name.contains("aspecto") || name.contains("apariencia") || ["Rojo", "Negro y rojo"].contains(key) { return .appearance }
            if name.contains("abrir libron") || name.contains("inicio") || name.contains("área seleccionada") { return .startup }
            if name.contains("cambios de esta") { return .changelog }
            if name.contains("actualiz") || name.contains("canal") { return .updates }
            if name.contains("grupo") || name.contains("paralelo") || name == "subir" || name == "bajar" || name.contains("agregar biblia") { return .groups }
            if name.contains("ocult") || name.contains("biblioteca") || name.contains("volver a mostrar") { return .library }
            if name.contains("sincroniz") || name.contains("vinculad") { return .synchronization }
            if name.contains("copiar versículo") || name.contains("formato de copia") { return .bibleCopy }
            if name.contains("temátic") || name.contains("tema") { return .topics }
            if name.contains("buscar") || name.contains("búsqueda") { return .search }
            if name.contains("resaltar") || name.contains("marcación") || name.contains("nota sobre") { return .marks }
            if name.contains("favorito") { return .favorites }
            if name.contains("imagen") || name.contains("mapa") { return .maps }
            if name.contains("exportar") || name.contains("imprimir") || name.contains("copiar selección") { return .output }
            if name.contains("documento") || name.contains("archivo de notas") || name.contains("lista de versículos") { return .documents }
            if name.contains("versión instalada") || name.contains("revisión") || name.contains("procesador") || name.contains("licencia") || name.contains("información") { return .information }
            if name == "libro" || name == "capítulo" { return .bibleReading }
            if name.contains("referencia") || name.contains("artículo") || name.contains("contenido") || name.contains("historial") || name.contains("atrás") || name.contains("adelante") || name.contains("acciones de lectura") { return .navigation }
            if name.contains("panel") || name.contains("ventana") || name.contains("mosaico") || name.contains("cascada") { return .workspace }
        }
        if labels.contains("Red") || labels.contains("Dark") { return .appearance }
        for topic in [Self.library, .groups, .updates, .information, .reading, .appearance] {
            if windowTitle == AppStrings.text(topic.title, language: language) { return topic }
        }
        if windowTitle == AppStrings.text("General", language: language) { return .appearance }
        if windowTitle == AppStrings.text("Lectura", language: language) { return .reading }
        if windowTitle == AppStrings.text("Mi biblioteca", language: language) { return .library }
        return .workspace
    }
}

@MainActor final class FeatureHelp: NSObject {
    static let shared = FeatureHelp()
    private static let itemID = NSUserInterfaceItemIdentifier("org.libronx.whats-this")
    private var monitor: Any?
    private var capture: Capture?
    private var helpWindow: NSWindow?
    private struct WeakRegion { weak var view: HelpRegionView? }
    private var regions: [WeakRegion] = []
    func register(_ view: HelpRegionView) {
        regions.removeAll { $0.view == nil || $0.view === view }
        regions.append(WeakRegion(view: view))
    }
    func unregister(_ view: HelpRegionView) { regions.removeAll { $0.view == nil || $0.view === view } }
    private func taggedTopic(for event: NSEvent) -> FeatureHelpTopic? {
        regions.compactMap(\.view).filter { view in
            view.window === event.window && !view.isHiddenOrHasHiddenAncestor &&
            view.bounds.contains(view.convert(event.locationInWindow, from: nil)) && view.isFrontmostReader(at: event.locationInWindow)
        }.min { a, b in a.bounds.width * a.bounds.height < b.bounds.width * b.bounds.height }?.topic
    }
    @MainActor private final class Capture {
        weak var window: NSWindow?
        let event: NSEvent
        let topic: FeatureHelpTopic
        let windows: Set<Int>
        let created = Date()
        var hasMenu = false
        init(window: NSWindow, event: NSEvent, topic: FeatureHelpTopic) {
            self.window = window; self.event = event; self.topic = topic
            windows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        }
    }
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown { self.capture = nil; return event }
            if event.type == .rightMouseDown, let window = event.window {
                guard window.identifier?.rawValue != "org.libronx.feature-help" else { self.capture = nil; return event }
                var object = window.accessibilityHitTest(window.convertPoint(toScreen: event.locationInWindow))
                var labels: [String] = []
                var explicitTopic: FeatureHelpTopic?
                var inToolbar = window.toolbar != nil && event.locationInWindow.y > window.contentLayoutRect.maxY
                for _ in 0..<10 {
                    guard let ax = object as? any NSAccessibilityProtocol else { break }
                    if let identifier = ax.accessibilityIdentifier(), identifier.hasPrefix("feature-help."),
                       let topic = FeatureHelpTopic(rawValue: String(identifier.dropFirst("feature-help.".count))) {
                        explicitTopic = explicitTopic ?? topic
                    }
                    if let title = ax.accessibilityTitle(), !title.isEmpty, title.count < 200 { labels.append(title) }
                    if let label = ax.accessibilityLabel(), !label.isEmpty, label.count < 200 { labels.append(label) }
                    if ax.accessibilityRole() == .toolbar { inToolbar = true }
                    if ax.accessibilityRole() == .textArea { labels.append(L("Acciones de lectura")) }
                    if let help = ax.accessibilityHelp(), !help.isEmpty, help.count < 200 { labels.append(help) }
                    object = ax.accessibilityParent()
                }
                self.capture = Capture(window: window, event: event,
                    topic: self.taggedTopic(for: event) ?? explicitTopic ?? (inToolbar ? .toolbar : .resolve(labels: labels, windowTitle: window.title, language: AppLanguage.saved())))
            } else if event.type == .rightMouseUp, let capture = self.capture, capture.window === event.window {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak capture] in
                    guard let self, let capture, self.capture === capture, !capture.hasMenu,
                          let view = capture.window?.contentView else { return }
                    // Title-bar layout popovers keep their existing interaction.
                    guard !NSApp.windows.contains(where: { $0.isVisible && !capture.windows.contains($0.windowNumber) && $0.className.contains("Popover") }) else { return }
                    let menu = NSMenu(); self.addItem(to: menu, topic: capture.topic)
                    menu.popUp(positioning: nil, at: view.convert(capture.event.locationInWindow, from: nil), in: view)
                }
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; capture = nil
        NotificationCenter.default.removeObserver(self)
    }
    @objc private func menuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, let capture,
              Date().timeIntervalSince(capture.created) < 5, menu.supermenu == nil,
              menu !== NSApp.mainMenu else { return }
        capture.hasMenu = true
        addItem(to: menu, topic: capture.topic)
    }
    /// Appends help without replacing text editing, row actions or toolbar menus.
    func addItem(to menu: NSMenu, topic: FeatureHelpTopic) {
        if let existing = menu.items.first(where: { $0.identifier == Self.itemID }) {
            existing.representedObject = topic.rawValue; return
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: L("¿Qué es esto?"), action: #selector(explain(_:)), keyEquivalent: "")
        item.identifier = Self.itemID; item.target = self; item.representedObject = topic.rawValue
        menu.addItem(item)
    }
    @objc private func explain(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let topic = FeatureHelpTopic(rawValue: raw) else { return }
        // Let native menu tracking finish before presenting a sheet.
        DispatchQueue.main.async { [weak self] in self?.show(topic) }
    }
    func show(_ topic: FeatureHelpTopic) {
        let window: NSWindow
        if let existing = helpWindow { window = existing }
        else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("org.libronx.feature-help")
            window.contentMinSize = NSSize(width: 420, height: 180)
            window.center(); helpWindow = window
        }
        let contentSize = window.contentView?.bounds.size ?? NSSize(width: 540, height: 560)
        window.title = L(topic.title)
        let controller = NSHostingController(rootView: FeatureHelpView(topic: topic) { [weak window] in window?.close() }
            .modifier(AppInterfaceLanguage()))
        controller.sizingOptions = []
        window.contentViewController = controller
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = FeatureHelpWindowLayout.fittingSize(topic: topic, language: AppPreferences.shared.language,
            width: min(max(420, contentSize.width), screenFrame.width - 40), maximumHeight: screenFrame.height - 80)
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX,
            y: min(max(top, screenFrame.minY + window.frame.height), screenFrame.maxY)))
        window.makeKeyAndOrderFront(nil)
    }
}
