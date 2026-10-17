import AppKit
import SwiftUI
import Observation
import LibronixCore

actor DictionaryLookupSource {
    static let shared = DictionaryLookupSource()
    nonisolated static func key(_ text: String) -> String { LibronDictionaryIndex.key(text) }
    func lookup(_ word: String, in resource: LibraryResource) async throws -> ReaderPage? {
        guard let entry = try await LibronDictionaryIndexService.shared.match(word, in: resource) else { return nil }
        return try await ReaderSession.read(resource, .init(ordinal: entry.ordinal))
    }
}
struct DictionaryMatch: Identifiable {
    let resource: LibraryResource
    let entry: LibronDictionaryEntry
    var id: String { resource.id }
}
@MainActor @Observable final class DictionaryController {
    var word = ""
    var resourceID = ""
    var page: ReaderPage?
    var matches: [DictionaryMatch] = []
    var status = ""
    var isLoading = false
    var indexErrors: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var popover: NSPopover?
    @ObservationIgnored private var panel: NSWindowController?
    @ObservationIgnored private var internalReaderID: UUID?
    nonisolated static func singleWord(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !word.isEmpty, word.utf16.count <= 128,
              word.range(of: #"^[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*$"#, options: .regularExpression) != nil else { return nil }
        return word
    }
    func dictionaries(in workspace: StudyWorkspace) -> [LibraryResource] { workspace.dictionaryGroup }
    func prepare(_ resources: [LibraryResource]) async {
        for resource in resources where LibronDictionaryIndex.supports(resource) {
            do {
                if resource.format == .libronDictionary { _ = try LibronDictionaryDatabase.count(resource.location) }
                else { _ = try await LibronDictionaryIndexService.shared.index(resource) }
                indexErrors[resource.id] = nil
            }
            catch is CancellationError { return }
            catch { indexErrors[resource.id] = error.localizedDescription }
        }
    }
    func selectionChanged(_ text: String, workspace: StudyWorkspace) {
        guard workspace.readers.contains(where: \.isDictionary) || popover?.isShown == true || panel?.window?.isVisible == true else { return }
        guard let value = Self.singleWord(text) else {
            generation += 1; task?.cancel(); page = nil; word = ""; matches = []; status = ""; isLoading = false
            for reader in workspace.readers where reader.isDictionary { reader.clearDictionaryDefinition() }
            return
        }
        guard word != value else { return }
        if let reader = workspace.readers.first(where: \.isDictionary) { internalReaderID = reader.id }
        lookup(value, workspace: workspace)
    }
    func lookup(_ value: String, workspace: StudyWorkspace, preferredID: String? = nil, allowsFallback: Bool = false) {
        generation += 1; let token = generation
        task?.cancel(); page = nil; matches = []
        guard let value = Self.singleWord(value) else { word = ""; status = ""; isLoading = false; return }
        word = value; status = ""; isLoading = true
        if let id = internalReaderID, let reader = workspace.readers.first(where: { $0.id == id }) {
            reader.showDictionary(reader.resource, word: value, page: nil)
            reader.error = nil; reader.isLoading = true
        }
        let language = workspace.activeReader?.resource.languages.first.map(LibraryLanguages.canonical) ?? "es"
        let dictionaries = dictionaries(in: workspace).sorted { a, b in
            func rank(_ r: LibraryResource) -> Int {
                if r.id == preferredID { return 0 }
                let languages = r.languages.map(LibraryLanguages.canonical)
                let languageRank = languages.first == language ? 0 : languages.contains(language) ? 2 : 4
                let general = LibronMetadata.deriving(r).resourceType != "Léxico" && !r.title.localizedCaseInsensitiveContains("idiomas bíblicos")
                return languageRank + (general ? 1 : 2)
            }
            return rank(a) == rank(b) ? a.title.localizedStandardCompare(b.title) == .orderedAscending : rank(a) < rank(b)
        }
        task = Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            var found: [DictionaryMatch] = []
            for resource in dictionaries {
                do {
                    try Task.checkCancellation()
                    if let entry = try await LibronDictionaryIndexService.shared.match(value, in: resource) {
                        found.append(.init(resource: resource, entry: entry))
                        if found.count == 1, preferredID == nil || preferredID == resource.id {
                            let result = try await ReaderSession.read(resource, .init(ordinal: entry.ordinal))
                            guard self.generation == token, !Task.isCancelled else { return }
                            self.resourceID = resource.id; self.page = result; self.matches = found
                        }
                    }
                    self.indexErrors[resource.id] = nil
                } catch is CancellationError { return }
                catch { self.indexErrors[resource.id] = error.localizedDescription }
            }
            guard self.generation == token, !Task.isCancelled else { return }
            self.matches = found
            let chosen = found.first { $0.id == preferredID } ?? (preferredID == nil || allowsFallback ? found.first : nil)
            self.resourceID = chosen?.id ?? preferredID ?? dictionaries.first?.id ?? ""
            do {
                let result: ReaderPage?
                if let chosen { result = try await ReaderSession.read(chosen.resource, .init(ordinal: chosen.entry.ordinal)) } else { result = nil }
                guard self.generation == token, !Task.isCancelled else { return }
                self.page = result; self.status = result == nil ? L("No se encontró una definición en este diccionario.") : ""
                self.isLoading = false
                if let id = self.internalReaderID, let reader = workspace.readers.first(where: { $0.id == id }),
                   let resource = dictionaries.first(where: { $0.id == self.resourceID }) {
                    reader.showDictionary(resource, word: value, page: result)
                    workspace.connect(reader)
                }
            } catch {
                if self.generation == token {
                    self.status = error.localizedDescription; self.isLoading = false
                    if let id = self.internalReaderID, let reader = workspace.readers.first(where: { $0.id == id }) {
                        reader.isLoading = false; reader.error = self.status
                    }
                }
            }
        }
    }
    func show(_ value: String, workspace: StudyWorkspace, anchor: NSView? = nil, rect: NSRect? = nil) {
        internalReaderID = workspace.readers.first(where: \.isDictionary)?.id
        lookup(value, workspace: workspace)
        let view = DictionaryQuickView(workspace: workspace, controller: self).modifier(AppInterfaceLanguage())
        if let anchor, anchor.window != nil {
            panel?.close(); popover?.close()
            let popover = NSPopover(); popover.behavior = .transient; popover.animates = true
            popover.contentViewController = NSHostingController(rootView: view)
            popover.contentSize = .init(width: 420, height: 350)
            self.popover = popover
            popover.show(relativeTo: rect ?? anchor.visibleRect, of: anchor, preferredEdge: .maxY)
        } else {
            popover?.close()
            if panel == nil {
                let window = NSPanel(contentViewController: NSHostingController(rootView: view))
                window.title = L("Diccionarios"); window.styleMask = [.titled,.closable,.resizable,.utilityWindow]
                window.setContentSize(.init(width: 420, height: 350)); window.isReleasedWhenClosed = false
                window.level = .floating; window.center(); panel = NSWindowController(window: window)
            }
            panel?.showWindow(nil)
        }
    }
    func openInside(workspace: StudyWorkspace) {
        popover?.close(); panel?.close()
        let resources = dictionaries(in: workspace)
        guard let resource = resources.first(where: { $0.id == resourceID }) ?? resources.first else { return }
        let reader = workspace.readers.first(where: \.isDictionary) ?? workspace.open(resource, startReading: false)
        internalReaderID = reader.id
        if !word.isEmpty { reader.showDictionary(resource, word: word, page: page); workspace.connect(reader) }
        else { reader.load(.init(ordinal: 0)) }
        workspace.activate(reader)
    }
    func lookupInside(_ word: String, resource: LibraryResource, reader: ReaderSession, workspace: StudyWorkspace, allowsFallback: Bool = true) {
        internalReaderID = reader.id
        if word.isEmpty {
            generation += 1; task?.cancel()
            reader.showDictionary(resource, word: "", page: nil)
            workspace.connect(reader); reader.load(.init(ordinal: 0))
            return
        }
        reader.dictionaryWord = word
        lookup(word, workspace: workspace, preferredID: resource.id, allowsFallback: allowsFallback)
    }
    func cycleQuick(backwards: Bool, workspace: StudyWorkspace) {
        guard matches.count > 1, let i = matches.firstIndex(where: { $0.id == resourceID }) else { return }
        let id = matches[(i + (backwards ? matches.count - 1 : 1)) % matches.count].id
        lookup(word, workspace: workspace, preferredID: id)
    }
}

@MainActor extension StudyWorkspace {
    var dictionaryGroup: [LibraryResource] {
        availableResources.filter(LibronDictionaryIndex.supports).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    /// A queried reader navigates only the completed matches for that word.
    /// The library's automatic dictionary group remains the full collection.
    func dictionaryChoices(for reader: ReaderSession) -> [LibraryResource] {
        if reader.dictionaryWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return dictionaryGroup }
        guard !dictionary.isLoading,
              DictionaryController.singleWord(reader.dictionaryWord) != nil,
              DictionaryLookupSource.key(reader.dictionaryWord) == DictionaryLookupSource.key(dictionary.word) else { return [] }
        let matchingIDs = Set(dictionary.matches.map(\.id))
        return dictionaryGroup.filter { matchingIDs.contains($0.id) }
    }
    func cycleDictionary(_ reader: ReaderSession, backwards: Bool = false) {
        let resources = dictionaryChoices(for: reader)
        guard reader.isDictionary, !resources.isEmpty else { return }
        let index = resources.firstIndex(where: { $0.id == reader.resource.id })
        let nextIndex = index.map { ($0 + (backwards ? resources.count - 1 : 1)) % resources.count }
            ?? (backwards ? resources.count - 1 : 0)
        let next = resources[nextIndex]
        guard next.id != reader.resource.id else { return }
        dictionary.lookupInside(reader.dictionaryWord, resource: next, reader: reader, workspace: self, allowsFallback: false)
    }
}
struct DictionaryQuickView: View {
    let workspace: StudyWorkspace
    @Bindable var controller: DictionaryController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(controller.word).font(.title2.bold())
                Spacer()
                if controller.isLoading { ProgressView().controlSize(.small) }
                Button { controller.cycleQuick(backwards: true, workspace: workspace) } label: { Image(systemName: "chevron.left") }.disabled(controller.matches.count < 2)
                Button { controller.cycleQuick(backwards: false, workspace: workspace) } label: { Image(systemName: "chevron.right") }.disabled(controller.matches.count < 2)
            }
            if !controller.matches.isEmpty {
                Picker(L("Diccionario"), selection: Binding(get: { controller.resourceID }, set: { controller.lookup(controller.word, workspace: workspace, preferredID: $0) })) {
                    ForEach(controller.matches) { match in Text(match.resource.title).tag(match.id) }
                }.labelsHidden()
            }
            if let page = controller.page { DictionaryDefinitionView(page: page) }
            else { Text(controller.status.isEmpty ? L("Buscando…") : controller.status).foregroundStyle(.secondary); Spacer(minLength: 0) }
            Divider()
            HStack {
                HelpButton(topic: .dictionary); Spacer()
                Button(L("Abrir dentro de Libron-X")) { controller.openInside(workspace: workspace) }
                    .disabled(controller.resourceID.isEmpty)
            }
        }.padding(16).frame(width: 420, height: 350).modifier(MacPanelControlPresentation())
    }
}
struct DictionaryReaderToolbar: View {
    @Bindable var reader: ReaderSession
    let workspace: StudyWorkspace
    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 600 { controls(compact: false) }
                else if geometry.size.width >= 460 { controls(compact: true) }
                else {
                    HStack(spacing: 8) {
                        searchField.frame(minWidth: 60, idealWidth: 100, maxWidth: 140)
                        Spacer(minLength: 4)
                        MacReaderControlGroup {
                            ReaderZoomMenu(reader: reader, activate: { workspace.activate(reader) })
                            noteButton
                            ReaderMarkupMenu(workspace: workspace, reader: reader)
                            actions
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var choices: [LibraryResource] { workspace.dictionaryChoices(for: reader) }
    private var canCycle: Bool { choices.count > 1 || (choices.count == 1 && choices.first?.id != reader.resource.id) }
    private func controls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            searchField.frame(minWidth: compact ? 70 : 140, idealWidth: compact ? 160 : 240, maxWidth: compact ? 180 : 260)
            Spacer(minLength: 8)
            MacReaderControlGroup {
                previousDictionary
                dictionaryMenu
                nextDictionary
            }
            MacReaderControlGroup {
                if !compact {
                    MacToolbarButton("Buscar en este recurso", "magnifyingglass") { workspace.activate(reader); reader.showFind() }
                    MacToolbarButton("Contenido", "sidebar.left") { workspace.activate(reader); reader.showsContents.toggle() }
                }
                ReaderZoomMenu(reader: reader, activate: { workspace.activate(reader) })
                noteButton
                ReaderMarkupMenu(workspace: workspace, reader: reader)
                actions
            }
        }
    }
    private var noteButton: some View {
        MacToolbarButton("Agregar nota", "square.and.pencil") { workspace.activate(reader); workspace.addNoteForSelection(reader) }
            .featureHelpTarget(.documents)
    }
    private var searchField: some View {
        MacToolbarSearchField(text: $reader.dictionaryWord, prompt: L("Palabra"), onSubmit: search)
            .frame(height: 32).modifier(MacToolbarSearchSurface())
            .help(L("Buscar en diccionario"))
    }
    private var previousDictionary: some View {
        MacToolbarButton("Diccionario anterior", "chevron.left") { workspace.cycleDictionary(reader, backwards: true) }.disabled(!canCycle)
    }
    private var nextDictionary: some View {
        MacToolbarButton("Diccionario siguiente", "chevron.right") { workspace.cycleDictionary(reader) }.disabled(!canCycle)
    }
    @ViewBuilder private var dictionaryItems: some View {
        Text(L("Grupo de diccionarios"))
        ForEach(choices) { resource in
            Button((reader.resource.id == resource.id ? "✓ " : "") + resource.title) {
                workspace.dictionary.lookupInside(reader.dictionaryWord, resource: resource, reader: reader, workspace: workspace, allowsFallback: false)
            }
        }
    }
    private var dictionaryMenu: some View {
        Menu { dictionaryItems } label: { MacToolbarLabel("Grupo de diccionarios", "character.book.closed") }
            .menuIndicator(.hidden).help(L("Grupo de diccionarios")).disabled(choices.isEmpty)
    }
    private func search() {
        workspace.activate(reader)
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        workspace.dictionary.lookupInside(reader.dictionaryWord, resource: reader.resource, reader: reader, workspace: workspace)
    }
    private var actions: some View {
        Menu {
            Button(L("Diccionario anterior"), systemImage: "chevron.left") { workspace.cycleDictionary(reader, backwards: true) }.disabled(!canCycle)
            Menu(L("Grupo de diccionarios"), systemImage: "character.book.closed") { dictionaryItems }.disabled(choices.isEmpty)
            Button(L("Diccionario siguiente"), systemImage: "chevron.right") { workspace.cycleDictionary(reader) }.disabled(!canCycle)
            Divider()
            Button(L("Contenido")) { workspace.activate(reader); reader.showsContents.toggle() }
            Button(L("Panel localizador")) { workspace.activate(reader); reader.showsLocator.toggle() }
            Button(L("Buscar en este recurso")) { workspace.activate(reader); reader.showFind() }
            Button(L("Artículo anterior")) { workspace.activate(reader); reader.previousArticle() }.disabled(!reader.canGoToPreviousArticle)
            Button(L("Artículo siguiente")) { workspace.activate(reader); reader.nextArticle() }.disabled(!reader.canGoToNextArticle)
            Divider()
            ReaderOutputMenuItems(reader: reader, workspace: workspace)
            Divider()
            Button(L("Propiedades…")) { workspace.activate(reader); workspace.activeTool = .information }
            Button(L("Duplicar lectura")) { workspace.duplicate(reader) }
            Button(L("Cerrar lectura")) { workspace.close(reader) }
        } label: { MacToolbarLabel("Acciones de lectura", "ellipsis") }
            .menuIndicator(.hidden).help(L("Acciones de lectura"))
    }
}

struct DictionaryDefinitionView: NSViewRepresentable {
    let page: ReaderPage
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = NSTextView(); text.drawsBackground = false; text.isEditable = false; text.isSelectable = true
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
