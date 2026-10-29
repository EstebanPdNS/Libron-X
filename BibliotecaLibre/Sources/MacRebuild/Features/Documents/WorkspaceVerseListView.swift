import AppKit
import SwiftUI
import LibronixCore

struct WorkspaceVerseListView: View {
    @Bindable var workspace: StudyWorkspace
    @Binding var document: StudyDocument
    @Binding var selectedVerse: UUID?
    let extractReferences: () -> Void
    @RebuildViewState private var reference = ""
    @RebuildViewState private var text = VerseListTextController()
    @RebuildViewState private var editing: StudyVerseEntry?
    @RebuildViewState private var editDraft = ""
    private var showsText: Bool { ["TextOnly", "BothTwoColumns"].contains(document.presentation) }
    private var bibles: [LibraryResource] { workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .bible)) }
    private var edition: LibraryResource? { document.verseListEdition?.resolve(in: workspace.availableResources) }
    private var editionSelection: Binding<StudyVerseListEdition?> {
        Binding(get: { document.verseListEdition }, set: {
            document.schemaVersion = max(4, document.schemaVersion); document.verseListEdition = $0
        })
    }
    private func synchronize() { text.synchronize(document: document, resources: workspace.availableResources) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(L("Referencia bíblica"), text: $reference).macInputStyle().onSubmit(add)
                Button(L("Agregar"), action: add).disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                MacToolbarButton("Extraer referencias…", "text.badge.plus", action: extractReferences)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Presentación")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Presentación"), value: presentationTitle, selection: $document.presentation, fillsWidth: true) {
                        Text(L("Referencias")).tag("ReferencesOnly")
                        Text(L("Solo texto")).tag("TextOnly")
                        Text(L("Referencias y texto")).tag("BothTwoColumns")
                        if !["ReferencesOnly", "TextOnly", "BothTwoColumns"].contains(document.presentation) {
                            Text(verbatim: document.presentation).tag(document.presentation)
                        }
                    }
                }.frame(width: 200)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Biblia")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Biblia"), value: edition?.title ?? document.verseListEdition?.title ?? L("Selecciona un recurso"), selection: editionSelection, fillsWidth: true) {
                        Text(L("Selecciona un recurso")).tag(Optional<StudyVerseListEdition>.none)
                        ForEach(bibles) { Text($0.title).tag(Optional(StudyVerseListEdition($0))) }
                        if let saved = document.verseListEdition, !bibles.contains(where: { saved.resolve(in: [$0]) != nil }) {
                            Text(verbatim: saved.title).tag(Optional(saved))
                        }
                    }
                }
                if text.isLoading {
                    MacToolbarButton("Cancelar", "xmark") { text.cancel() }
                } else {
                    MacToolbarButton("Cargar textos", "arrow.clockwise") {
                        if let edition { text.load(document: document, resource: edition) }
                    }.disabled(edition == nil || document.verses.isEmpty)
                }
            }
            if let saved = document.verseListEdition, edition == nil {
                Text(LF("Edición guardada no disponible: {edition}. Vuelve a añadirla a la biblioteca o elige otra.", ["edition": saved.title]))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if showsText && edition == nil {
                Text(L("Selecciona una Biblia y carga los textos.")).font(.caption).foregroundStyle(.secondary)
            }
            if text.isLoading { ProgressView().controlSize(.small) }
            if let error = text.error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let edition = text.report?.edition, !edition.complete {
                Text(L("Cobertura parcial: no se puede confirmar la ausencia de versículos.")).font(.caption).foregroundStyle(.secondary)
                if let failure = edition.failure { Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            ScrollViewReader { scroll in
                List(document.verses, selection: $selectedVerse) { verse in
                    HStack(alignment: .top, spacing: 12) {
                        if document.presentation != "TextOnly" || text.rowsByID[verse.id]?.verses.isEmpty != false {
                            Text(verse.reference).textSelection(.enabled)
                                .frame(width: showsText ? 144 : nil, alignment: .leading)
                        }
                        if showsText {
                            VStack(alignment: .leading, spacing: 6) { content(verse.id) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .environment(\.layoutDirection, NSParagraphStyle.defaultWritingDirection(forLanguage: edition?.languages.first) == .rightToLeft ? .rightToLeft : .leftToRight)
                        } else { Spacer(minLength: 8) }
                        Button(L("Abrir")) { open(verse) }.disabled(!canOpen(verse))
                    }.padding(.vertical, 5).tag(verse.id).id(verse.id)
                }
                .accessibilityLabel(L("Lista de versículos"))
                .onDeleteCommand(perform: removeSelected)
                .onChange(of: selectedVerse) { if let selectedVerse { scroll.scrollTo(selectedVerse, anchor: .center) } }
                .onAppear { if let selectedVerse { scroll.scrollTo(selectedVerse, anchor: .center) } }
            }
            MacReaderToolbarSurface {
                HStack(spacing: 12) {
                    MacReaderControlGroup {
                        MacToolbarButton("Editar referencia", "pencil") {
                            editing = document.verses.first { $0.id == selectedVerse }; editDraft = editing?.reference ?? ""
                        }.disabled(selectedVerse == nil)
                        MacToolbarButton("Eliminar versículo", "trash", action: removeSelected).disabled(selectedVerse == nil)
                    }
                    MacReaderControlGroup {
                        Button(L("Ordenar referencias")) {
                            do { try StudyVerseOrganization.sortCanonically(&document) }
                            catch { workspace.error = L("No se pueden ordenar todas las referencias. Revisa las referencias desconocidas o ambiguas.") }
                        }.disabled(document.verses.count < 2)
                    }
                    Spacer(minLength: 8)
                    MacReaderControlGroup {
                        MacToolbarButton("Subir", "chevron.up") { move(-1) }.disabled(!canMove(-1))
                        MacToolbarButton("Bajar", "chevron.down") { move(1) }.disabled(!canMove(1))
                    }
                }
            }.padding(.horizontal, 8).padding(.bottom, 8)
        }
        .onAppear(perform: synchronize)
        .onChange(of: document.verses) { synchronize() }
        .onChange(of: document.verseListEdition) { synchronize() }
        .onChange(of: workspace.availableResources) { synchronize() }
        .onDisappear { text.invalidate() }
        .alert(L("Editar referencia"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(L("Referencia bíblica"), text: $editDraft)
            Button(L("Cancelar"), role: .cancel) { editing = nil }
            Button(L("Guardar")) {
                guard let original = editing else { return }
                do { try StudyVerseOrganization.changeReference(original, to: editDraft, in: &document) }
                catch { workspace.error = error.localizedDescription }
                editing = nil
            }.disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editDraft.utf8.count > 4096)
        }
    }
    private var presentationTitle: String {
        switch document.presentation {
        case "ReferencesOnly": L("Referencias")
        case "TextOnly": L("Solo texto")
        case "BothTwoColumns": L("Referencias y texto")
        default: document.presentation
        }
    }
    private func add() {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096 else { return }
        let entry = StudyVerseEntry(reference: value)
        document.verses.append(entry); selectedVerse = entry.id; reference = ""
    }
    private func removeSelected() {
        guard let selectedVerse else { return }
        document.verses.removeAll { $0.id == selectedVerse }; self.selectedVerse = nil
    }
    private func canMove(_ offset: Int) -> Bool {
        guard let position = document.verses.firstIndex(where: { $0.id == selectedVerse }) else { return false }
        return document.verses.indices.contains(position + offset)
    }
    private func move(_ offset: Int) {
        guard let selectedVerse else { return }
        do { try StudyVerseOrganization.move(selectedVerse, by: offset, in: &document) }
        catch { workspace.error = error.localizedDescription }
    }
    private func canOpen(_ entry: StudyVerseEntry) -> Bool {
        if document.verseListEdition != nil {
            return edition != nil && text.report?.documentID == document.id && text.report?.edition?.resource == edition &&
                text.rowsByID[entry.id]?.reference == entry.reference && text.rowsByID[entry.id]?.verses.isEmpty == false
        }
        if let location = entry.location { return location.resolve(in: workspace.availableResources) != nil }
        return workspace.activeReader != nil
    }
    private func open(_ entry: StudyVerseEntry) {
        guard canOpen(entry) else { return }
        if document.verseListEdition != nil {
            guard let report = text.report, let edition = report.edition,
                  let verse = text.rowsByID[entry.id]?.verses.first,
                  workspace.availableResources.contains(edition.resource) else { return }
            do {
                try LibrarySearchFileStamp.verify(edition.sourceStamps)
                let reader = workspace.open(edition.resource, startReading: false)
                reader.load(.init(ordinal: verse.sectionOrdinal), selection: verse.sourceRange.nsRange,
                    expectedFingerprint: verse.sourceFingerprint, expectedSourceStamps: edition.sourceStamps)
                workspace.activeTool = nil
            } catch { workspace.error = error.localizedDescription }
        } else if let location = entry.location {
            guard let resource = location.resolve(in: workspace.availableResources) else { return }
            let reader = workspace.open(resource, startReading: false)
            reader.load(.init(ordinal: location.sectionOrdinal, reference: location.reference), expectedFingerprint: location.textFingerprint)
            workspace.activeTool = nil
        } else if let reader = workspace.activeReader {
            reader.locator = entry.reference; reader.changeLocatorMode(false)
            reader.locator = entry.reference; reader.goToReference(); workspace.activeTool = nil
        }
    }
    @ViewBuilder private func content(_ id: UUID) -> some View {
        if let row = text.rowsByID[id] {
            ForEach(Array(row.verses.enumerated()), id: \.offset) { _, verse in Text(verse.text).textSelection(.enabled) }
            switch row.state {
            case .available: EmptyView()
            case .partial: Text(L("Algunos versículos del rango no aparecen en esta edición.")).font(.caption).foregroundStyle(.secondary)
            case .missing: Text(L("Versículo ausente en esta edición.")).foregroundStyle(.secondary)
            case .unverified: Text(L("Versículo sin verificar en esta edición.")).foregroundStyle(.secondary)
            case .invalid: Text(L("Referencia no reconocida.")).foregroundStyle(.secondary)
            }
        }
    }
}
