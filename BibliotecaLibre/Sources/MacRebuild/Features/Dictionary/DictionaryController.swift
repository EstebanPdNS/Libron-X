import AppKit
import SwiftUI
import Observation
import LibronixCore

actor DictionaryLookupSource {
    static let shared = DictionaryLookupSource()
    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    func lookup(_ word: String, in resource: LibraryResource) async throws -> ReaderPage? {
        let needle = Self.key(word)
        if resource.format == .eSwordSQLite {
            let first = try ESwordResource.page(resource.location, ordinal: 0)
            guard let index = first.contents.firstIndex(where: { Self.key($0) == needle }) else { return nil }
            return try await ReaderSession.read(resource, .init(ordinal: index))
        }
        if resource.format == .libronixLLS, let catalog = try await LibronixTopicCatalogService.shared.catalog(resource) {
            for (i, named) in catalog.indexes.enumerated() {
                for (j, topic) in named.topics.enumerated() where Self.key(topic.text) == needle {
                    if let entry = try await LibronixTopicCatalogService.shared.articles(catalog, index: i, topic: j).first {
                        return try await ReaderSession.read(resource, .init(ordinal: entry.sectionOrdinal))
                    }
                }
            }
        }
        if TopicDirectorySource.supports(resource) {
            let directory = try await TopicDirectorySource.shared.directory(resource)
            guard let entry = directory.first(where: { Self.key($0.displayTitle) == needle }) else { return nil }
            return try await ReaderSession.read(resource, .init(ordinal: entry.sectionOrdinal))
        }
        return nil
    }
}
@MainActor @Observable final class DictionaryController {
    var word = ""
    var resourceID = ""
    var page: ReaderPage?
    var status = ""
    var isLoading = false
    var isInternal = false
    var frame = PaneFrame(x: 0.58, y: 0.08, width: 0.40, height: 0.78)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var panel: NSWindowController?
    var visible: Bool { isInternal || panel?.window?.isVisible == true }
    nonisolated static func singleWord(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !word.isEmpty, word.utf16.count <= 128,
              word.range(of: #"^[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*$"#, options: .regularExpression) != nil else { return nil }
        return word
    }
    func dictionaries(in workspace: StudyWorkspace) -> [LibraryResource] {
        workspace.availableResources.filter {
            let type = LibronMetadata.deriving($0).resourceType
            return type == "Diccionario o enciclopedia" || type == "Léxico"
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func selectionChanged(_ text: String, workspace: StudyWorkspace) {
        guard visible else { return }
        guard let value = Self.singleWord(text) else {
            generation += 1; task?.cancel(); page = nil; word = ""; status = ""; isLoading = false; return
        }
        guard word != value else { return }
        lookup(value, workspace: workspace)
    }
    func lookup(_ value: String, workspace: StudyWorkspace) {
        generation += 1; let token = generation
        task?.cancel(); page = nil
        guard let value = Self.singleWord(value) else { word = ""; status = ""; isLoading = false; return }
        word = value
        let dictionaries = dictionaries(in: workspace)
        if !dictionaries.contains(where: { $0.id == resourceID }) {
            let language = workspace.activeReader?.resource.languages.first.map(LibraryLanguages.canonical) ?? "es"
            let local = dictionaries.filter { $0.languages.map(LibraryLanguages.canonical).contains(language) }
            resourceID = local.first(where: { $0.title.localizedStandardContains("Nuevo Diccionario de la Biblia") })?.id ??
                local.first(where: { $0.title.localizedStandardContains("Smith") })?.id ?? local.first?.id ?? dictionaries.first?.id ?? ""
        }
        guard let resource = dictionaries.first(where: { $0.id == resourceID }) else { status = L("No hay diccionarios disponibles."); isLoading = false; return }
        status = ""; isLoading = true
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await DictionaryLookupSource.shared.lookup(value, in: resource)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.page = result; self.status = result == nil ? L("No se encontró una definición en este diccionario.") : ""; self.isLoading = false
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == token else { return }
                self.status = error.localizedDescription; self.isLoading = false
            }
        }
    }
    func show(_ value: String, workspace: StudyWorkspace) {
        lookup(value, workspace: workspace)
        if isInternal { return }
        if panel == nil {
            let view = DictionaryView(workspace: workspace, controller: self, compact: true).modifier(AppInterfaceLanguage())
            let window = NSPanel(contentViewController: NSHostingController(rootView: view))
            window.title = L("Diccionarios"); window.styleMask = [.titled,.closable,.resizable,.utilityWindow]
            window.setContentSize(.init(width: 460, height: 420)); window.isReleasedWhenClosed = false
            window.level = .floating; window.center(); panel = NSWindowController(window: window)
        }
        panel?.showWindow(nil); panel?.window?.makeKeyAndOrderFront(nil)
    }
    func openInside(workspace: StudyWorkspace) { panel?.close(); isInternal = true; workspace.showsHome = false }
    func close() { isInternal = false; panel?.close(); generation += 1; task?.cancel(); isLoading = false }
}
struct DictionaryView: View {
    let workspace: StudyWorkspace
    @Bindable var controller: DictionaryController
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("Diccionarios"), systemImage: "character.book.closed").font(.headline)
                Spacer(); HelpButton(topic: .dictionary)
                if compact {
                    Button(L("Abrir dentro de Libron-X")) { controller.openInside(workspace: workspace) }
                }
            }
            Picker(L("Diccionario"), selection: $controller.resourceID) {
                ForEach(controller.dictionaries(in: workspace)) { resource in Text(resource.title).tag(resource.id) }
            }.labelsHidden().onChange(of: controller.resourceID) { _, _ in controller.lookup(controller.word, workspace: workspace) }
            HStack {
                TextField(L("Palabra"), text: $controller.word).macInputStyle().onSubmit { controller.lookup(controller.word, workspace: workspace) }
                Button(L("Buscar")) { controller.lookup(controller.word, workspace: workspace) }
            }
            if controller.isLoading { ProgressView().controlSize(.small) }
            if !controller.status.isEmpty { Text(controller.status).foregroundStyle(.secondary).textSelection(.enabled) }
            if let page = controller.page {
                DictionaryDefinitionView(page: page)
            } else { Spacer(minLength: 0) }
        }.padding(14).frame(minWidth: 300, minHeight: 250).contextHelp(.dictionary).modifier(MacPanelControlPresentation())
    }
}
struct DictionaryDefinitionView: NSViewRepresentable {
    let page: ReaderPage
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainerInset = .init(width: 8, height: 8); scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let display = ReaderTypography.render(text: page.text, content: page.content, typography: page.typography, scale: 1.2)
        text.textStorage?.setAttributedString(display.text)
    }
}
struct InternalDictionaryPane: View {
    let workspace: StudyWorkspace
    @Bindable var controller: DictionaryController
    let canvas: CGSize
    @RebuildViewState private var origin: PaneFrame?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { controller.close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                Text(L("Diccionarios")).font(.headline); Spacer()
            }.padding(10).background(.bar).contentShape(Rectangle())
                .gesture(DragGesture().onChanged { drag in
                    let start = origin ?? controller.frame; origin = start
                    controller.frame.x = min(max(0, start.x + drag.translation.width / canvas.width), 1 - start.width)
                    controller.frame.y = min(max(0, start.y + drag.translation.height / canvas.height), 1 - start.height)
                }.onEnded { _ in origin = nil })
            Divider()
            DictionaryView(workspace: workspace, controller: controller)
            HStack { Spacer(); Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).padding(5)
                .gesture(DragGesture().onChanged { drag in
                    let start = origin ?? controller.frame; origin = start
                    controller.frame.width = min(1 - start.x, max(0.3, start.width + drag.translation.width / canvas.width))
                    controller.frame.height = min(1 - start.y, max(0.35, start.height + drag.translation.height / canvas.height))
                }.onEnded { _ in origin = nil })
            }
        }.background(.background, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)).shadow(radius: 8)
    }
}
