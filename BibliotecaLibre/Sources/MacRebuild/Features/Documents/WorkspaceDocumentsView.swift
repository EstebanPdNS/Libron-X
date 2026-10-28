import SwiftUI
import LibronixCore

private struct NoteMoveRequest: Identifiable {
    let id = UUID()
    let documentID: UUID
    let noteIDs: Set<UUID>
}
private struct NotePropertiesRequest: Identifiable {
    var id: UUID { note.id }
    let documentID: UUID
    let note: StudyNote
}

struct WorkspaceDocumentsView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var personal: WorkspacePersonalState
    @RebuildViewState private var selectedNotes: Set<UUID> = []
    private var selectedNote: UUID? {
        get { selectedNotes.count == 1 ? selectedNotes.first : nil }
        nonmutating set { selectedNotes = newValue.map { [$0] } ?? [] }
    }
    @RebuildViewState private var operationDocumentID: UUID?
    @RebuildViewState private var renamingID: UUID?
    @RebuildViewState private var renameDraft = ""
    @RebuildViewState private var showsRename = false
    @RebuildViewState private var deletionIDs: Set<UUID> = []
    @RebuildViewState private var showsDelete = false
    @RebuildViewState private var moveRequest: NoteMoveRequest?
    @RebuildViewState private var propertiesRequest: NotePropertiesRequest?
    @RebuildViewState private var extractionRequest: ReferenceExtractionRequest?
    @RebuildViewState private var selectedVerse: UUID?
    @RebuildViewState private var verseReference = ""
    @RebuildViewState private var verseBibleID = ""
    @RebuildViewState private var verseText = VerseListTextController()
    @FocusState private var noteBodyFocused: Bool
    private var documentIndex: Int? { personal.documents.firstIndex { $0.id == personal.selectedDocumentID } }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker(L("Documento"), selection: $personal.selectedDocumentID) {
                    Text(L("Selecciona un documento")).tag(Optional<UUID>.none)
                    ForEach(personal.documents) { document in Text(document.title).tag(Optional(document.id)) }
                }
                Menu(L("Nuevo")) {
                    Button(L("Archivo de notas")) { personal.create(.notebook) }
                    Button(L("Lista de versículos")) { personal.create(.verseList) }
                }
                Button(L("Abrir…"), action: workspace.openDocument)
                if let index = documentIndex { Button(L("Guardar como…")) { workspace.exportDocument(personal.documents[index]) } }
            }
            if let index = documentIndex {
                if let destination = workspace.personalSearchDestination,
                   destination.documentID == personal.selectedDocumentID,
                   (destination.field == .documentTitle ||
                    (destination.field == .verseEntry ? selectedVerse : selectedNote) == destination.entryID),
                   let field = try? PersonalReferenceProjection.validate(destination, documents: personal.documents) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Resultado de búsqueda")).font(.caption).foregroundStyle(.secondary)
                        Text((field.text as NSString).substring(with: destination.range.nsRange)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField(L("Nombre del documento"), text: $personal.documents[index].title).macInputStyle()
                if personal.documents[index].kind == .notebook { notebook(index) }
                else { verseList(index) }
            } else {
                Spacer(); Text(L("Crea o abre un documento de estudio.")).foregroundStyle(.secondary); Spacer()
            }
            if let error = personal.loadError { Text(error).foregroundStyle(.red).font(.caption) }
            Text(L("Los cambios se guardan en los datos propios de esta aplicación.")).font(.caption).foregroundStyle(.secondary)
        }.padding(16)
            .onAppear {
                selectPendingNote()
                applySearchNavigation()
            }
            .onChange(of: personal.documents) { workspace.personalSearchDestination = nil; verseText.invalidate(); personal.scheduleSave() }
            .onChange(of: verseBibleID) { verseText.invalidate() }
            .onChange(of: workspace.availableResources) { verseText.invalidate() }
            .onDisappear { verseText.invalidate() }
            .onChange(of: personal.selectedDocumentID) {
                let available = documentIndex.map { Set(personal.documents[$0].notes.map(\.id)) } ?? []
                selectedNotes.formIntersection(available); selectedVerse = nil; applySearchNavigation()
            }
            .onChange(of: workspace.personalNavigationID) { applySearchNavigation() }
            .onChange(of: workspace.pendingNoteID) { selectPendingNote() }
            .alert(L("Renombrar nota"), isPresented: $showsRename) {
                TextField(L("Título de la nota"), text: $renameDraft)
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Guardar")) {
                    guard let documentID = operationDocumentID, let noteID = renamingID else { return }
                    do { try personal.renameNote(noteID, in: documentID, title: renameDraft) }
                    catch { workspace.error = error.localizedDescription }
                }.disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(L("Borrar notas"), isPresented: $showsDelete) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Borrar"), role: .destructive) {
                    guard let documentID = operationDocumentID else { return }
                    do {
                        try personal.deleteNotes(deletionIDs, in: documentID)
                        if personal.selectedDocumentID == documentID { selectedNotes.subtract(deletionIDs) }
                    } catch { workspace.error = error.localizedDescription }
                }
            } message: {
                Text(LF("Notas que se borrarán: {count}. ¿Quieres continuar?", ["count": String(deletionIDs.count)]))
            }
            .sheet(item: $moveRequest) { request in
                NoteMoveView(personal: personal, sourceID: request.documentID, ids: request.noteIDs)
                    .modifier(AppInterfaceLanguage())
            }
            .sheet(item: $propertiesRequest) { request in
                NotePropertiesView(personal: personal, documentID: request.documentID, note: request.note)
                    .modifier(AppInterfaceLanguage())
            }
            .sheet(item: $extractionRequest) { request in
                StudyReferenceExtractionView(personal: personal, destinationID: request.id)
            }
    }
    private func selectPendingNote() {
        guard let id = workspace.pendingNoteID else { return }
        selectedNote = id; workspace.pendingNoteID = nil; noteBodyFocused = true
    }
    private func applySearchNavigation() {
        guard let destination = workspace.personalSearchDestination,
              destination.documentID == personal.selectedDocumentID else { return }
        do {
            _ = try PersonalReferenceProjection.validate(destination, documents: personal.documents)
            if destination.field == .verseEntry { selectedVerse = destination.entryID }
            else { selectedNote = destination.entryID }
        } catch { workspace.error = error.localizedDescription; workspace.personalSearchDestination = nil }
    }
    private func notebook(_ index: Int) -> some View {
        HSplitView {
            VStack(spacing: 8) {
                let entries = (try? StudyNoteOrganization.outline(personal.documents[index].notes)) ?? []
                ScrollViewReader { scroll in
                List(entries, selection: $selectedNotes) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                        Text(entry.note.title).lineLimit(2)
                    }.padding(.leading, CGFloat(min(entry.depth, 8)) * 12)
                        .help(entry.note.title).tag(entry.id).id(entry.id)
                        .accessibilityLabel(entry.note.title + ", " + LF("Nivel {number}", ["number": String(entry.depth + 1)]))
                }
                    .accessibilityIdentifier("notes.list")
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        Button(L("Renombrar nota")) { requestRename(ids, index: index) }.disabled(ids.count != 1)
                        Button(L("Duplicar notas")) { duplicate(ids, index: index) }.disabled(ids.isEmpty)
                        Button(L("Mover notas…")) { requestMove(ids, index: index) }.disabled(ids.isEmpty)
                        Button(L("Propiedades de la nota")) { requestProperties(ids, index: index) }.disabled(ids.count != 1)
                        Button(L("Borrar notas"), role: .destructive) { requestDeletion(ids, index: index) }.disabled(ids.isEmpty)
                    }
                    .onDeleteCommand { requestDeletion(selectedNotes, index: index) }
                    .onAppear { if let selectedNote { scroll.scrollTo(selectedNote, anchor: .center) } }
                    .onChange(of: selectedNote) { if let selectedNote { scroll.scrollTo(selectedNote, anchor: .center) } }
                }
                MacReaderToolbarSurface {
                    MacReaderControlGroup {
                        MacToolbarButton("Agregar nota", "plus") { addNote(index: index) }
                        Menu {
                            Button(L("Agregar subnota")) { addNote(index: index, parentID: selectedNote) }.disabled(selectedNote == nil)
                            Button(L("Renombrar nota")) { requestRename(selectedNotes, index: index) }.disabled(selectedNote == nil)
                            Button(L("Duplicar notas")) { duplicate(selectedNotes, index: index) }.disabled(selectedNotes.isEmpty)
                            Button(L("Mover notas…")) { requestMove(selectedNotes, index: index) }.disabled(selectedNotes.isEmpty)
                            Button(L("Propiedades de la nota")) { requestProperties(selectedNotes, index: index) }.disabled(selectedNote == nil)
                            Menu(L("Ordenar notas")) {
                                Button(L("Título")) { sort(.title, index: index) }
                                Button(L("Referencia")) { sort(.reference, index: index) }
                                Button(L("Última modificación")) { sort(.modified, index: index) }
                            }.disabled(entries.isEmpty)
                            Divider()
                            Button(L("Borrar notas"), role: .destructive) { requestDeletion(selectedNotes, index: index) }.disabled(selectedNotes.isEmpty)
                        } label: { Text(L("Acciones")).font(.callout) }
                            .fixedSize().help(L("Acciones de notas"))
                        Spacer(minLength: 8)
                        MacToolbarButton("Subir", "chevron.up") { move(-1, index: index) }.disabled(!canMove(-1, index: index))
                        MacToolbarButton("Bajar", "chevron.down") { move(1, index: index) }.disabled(!canMove(1, index: index))
                    }
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }.frame(minWidth: 240, idealWidth: 250, maxWidth: 260)
            VStack(alignment: .leading) {
                if let note = personal.documents[index].notes.firstIndex(where: { $0.id == selectedNote }) {
                    let documentID = personal.documents[index].id
                    let noteID = personal.documents[index].notes[note].id
                    StudyNoteTitleField(title: $personal.documents[index].notes[note].title, noteID: noteID,
                                        destination: workspace.personalSearchDestination, navigationID: workspace.personalNavigationID)
                    WorkspaceNoteEditor(note: personal.documents[index].notes[note], destination: workspace.personalSearchDestination,
                                        navigationID: workspace.personalNavigationID) { data in
                        do { try personal.updateNoteRichText(noteID, in: documentID, data: data) }
                        catch { workspace.error = error.localizedDescription }
                    }.focused($noteBodyFocused)
                    if let reference = PersonalReferenceProjection.anchor(personal.documents[index].notes[note]) {
                        Text(reference).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let location = personal.documents[index].notes[note].effectiveAnchor.location {
                        Button(L("Abrir referencia")) {
                            if let resource = location.resolve(in: workspace.resources) {
                                workspace.open(resource, destination: .init(ordinal: location.sectionOrdinal, reference: location.reference)); workspace.activeTool = nil
                            }
                        }
                    }
                } else {
                    Color.clear
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minWidth: 332, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private func addNote(index: Int, parentID: UUID? = nil) {
        var note = StudyNote(); note.sourceContentType = "text/plain"; note.parentID = parentID
        if parentID != nil { personal.documents[index].schemaVersion = 2 }
        personal.documents[index].notes.append(note); selectedNote = note.id; noteBodyFocused = true
    }
    private func duplicate(_ ids: Set<UUID>, index: Int) {
        do { selectedNotes = try personal.duplicateNotes(ids, in: personal.documents[index].id) }
        catch { workspace.error = error.localizedDescription }
    }
    private func requestMove(_ ids: Set<UUID>, index: Int) {
        guard !ids.isEmpty else { return }
        moveRequest = NoteMoveRequest(documentID: personal.documents[index].id, noteIDs: ids)
    }
    private func requestProperties(_ ids: Set<UUID>, index: Int) {
        guard ids.count == 1 else { return }
        guard let note = personal.documents[index].notes.first(where: { ids.contains($0.id) }) else { return }
        propertiesRequest = NotePropertiesRequest(documentID: personal.documents[index].id, note: note)
    }
    private func sort(_ order: StudyNoteSort, index: Int) {
        do { try personal.sortNotes(in: personal.documents[index].id, by: order) }
        catch { workspace.error = error.localizedDescription }
    }
    private func canMove(_ delta: Int, index: Int) -> Bool {
        guard let id = selectedNote, let note = personal.documents[index].notes.first(where: { $0.id == id }) else { return false }
        let siblings = personal.documents[index].notes.filter { $0.parentID == note.parentID }
        guard let position = siblings.firstIndex(where: { $0.id == id }) else { return false }
        return siblings.indices.contains(position + delta)
    }
    private func move(_ delta: Int, index: Int) {
        guard let id = selectedNote else { return }
        do { try personal.moveNote(id, in: personal.documents[index].id, by: delta) }
        catch { workspace.error = error.localizedDescription }
    }
    private func requestRename(_ ids: Set<UUID>, index: Int) {
        guard ids.count == 1, let note = personal.documents[index].notes.first(where: { ids.contains($0.id) }) else { return }
        operationDocumentID = personal.documents[index].id
        renamingID = note.id; renameDraft = note.title; showsRename = true
    }
    private func requestDeletion(_ ids: Set<UUID>, index: Int) {
        let valid = ids.intersection(Set(personal.documents[index].notes.map(\.id)))
        guard !valid.isEmpty else { return }
        operationDocumentID = personal.documents[index].id
        deletionIDs = valid; showsDelete = true
    }
    private func verseList(_ index: Int) -> some View {
        VStack {
            HStack {
                TextField(L("Referencia bíblica"), text: $verseReference).macInputStyle()
                Button(L("Agregar")) {
                    guard !verseReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    personal.documents[index].verses.append(.init(reference: verseReference)); verseReference = ""
                }
                Button(L("Extraer referencias…")) { extractionRequest = .init(id: personal.documents[index].id) }
            }
            HStack {
                Picker(L("Presentación"), selection: $personal.documents[index].presentation) {
                    Text(L("Referencias")).tag("ReferencesOnly")
                    Text(L("Solo texto")).tag("TextOnly")
                    Text(L("Referencias y texto")).tag("BothTwoColumns")
                    if !["ReferencesOnly", "TextOnly", "BothTwoColumns"].contains(personal.documents[index].presentation) {
                        Text(personal.documents[index].presentation).tag(personal.documents[index].presentation)
                    }
                }.fixedSize()
                if ["TextOnly", "BothTwoColumns"].contains(personal.documents[index].presentation) {
                    Picker(L("Biblia"), selection: $verseBibleID) {
                        Text(L("Selecciona un recurso")).tag("")
                        ForEach(workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .bible))) { resource in
                            Text(resource.title).tag(resource.id)
                        }
                    }
                    if verseText.isLoading { Button(L("Cancelar")) { verseText.invalidate() } }
                    else {
                        Button(L("Cargar textos")) {
                            if let resource = workspace.availableResources.first(where: { $0.id == verseBibleID && KeyLinkKind.bible.supports($0) }) {
                                verseText.load(document: personal.documents[index], resource: resource)
                            }
                        }.disabled(verseBibleID.isEmpty || personal.documents[index].verses.isEmpty)
                    }
                }
            }
            if ["TextOnly", "BothTwoColumns"].contains(personal.documents[index].presentation) {
                if verseText.isLoading { ProgressView().controlSize(.small) }
                if verseText.report == nil && !verseText.isLoading && verseText.error == nil && !personal.documents[index].verses.isEmpty {
                    Text(L("Selecciona una Biblia y carga los textos.")).font(.caption).foregroundStyle(.secondary)
                }
                if let error = verseText.error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let edition = verseText.report?.edition, !edition.complete {
                    Text(L("Cobertura parcial: no se puede confirmar la ausencia de versículos.")).font(.caption).foregroundStyle(.secondary)
                    if let failure = edition.failure { Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            ScrollViewReader { scroll in
            List(personal.documents[index].verses, selection: $selectedVerse) { verse in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if personal.documents[index].presentation != "TextOnly" || ![.available, .partial].contains(verseText.rowsByID[verse.id]?.state) {
                            Text(verse.reference).textSelection(.enabled)
                        }
                        if ["TextOnly", "BothTwoColumns"].contains(personal.documents[index].presentation) {
                            verseTextContent(verse.id)
                        }
                    }
                    Spacer()
                    Button(L("Abrir")) { openVerse(verse) }
                        .disabled(verseText.report == nil ? workspace.activeReader == nil : verseText.rowsByID[verse.id]?.verses.isEmpty != false)
                    Button { personal.documents[index].verses.removeAll { $0.id == verse.id } } label: { MacToolbarLabel(L("Eliminar versículo"), "trash") }
                }.tag(verse.id).id(verse.id)
            }
            .onAppear { if let selectedVerse { scroll.scrollTo(selectedVerse, anchor: .center) } }
            .onChange(of: selectedVerse) { if let selectedVerse { scroll.scrollTo(selectedVerse, anchor: .center) } }
            }
            MacReaderToolbarSurface {
                HStack {
                    MacReaderControlGroup {
                        Button(L("Ordenar referencias")) {
                            do { try StudyVerseOrganization.sortCanonically(&personal.documents[index]) }
                            catch { workspace.error = L("No se pueden ordenar todas las referencias. Revisa las referencias desconocidas o ambiguas.") }
                        }.disabled(personal.documents[index].verses.count < 2)
                    }
                    Spacer(minLength: 12)
                    MacReaderControlGroup {
                        MacToolbarButton("Subir", "chevron.up") { moveVerse(-1, index: index) }
                            .disabled(!canMoveVerse(-1, index: index))
                        MacToolbarButton("Bajar", "chevron.down") { moveVerse(1, index: index) }
                            .disabled(!canMoveVerse(1, index: index))
                    }
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
    private func openVerse(_ entry: StudyVerseEntry) {
        if let report = verseText.report {
            guard let edition = report.edition, let verse = verseText.rowsByID[entry.id]?.verses.first,
                  workspace.availableResources.contains(edition.resource) else { return }
            do {
                try LibrarySearchFileStamp.verify(edition.sourceStamps)
                let reader = workspace.open(edition.resource, startReading: false)
                reader.load(.init(ordinal: verse.sectionOrdinal), selection: verse.sourceRange.nsRange,
                            expectedFingerprint: verse.sourceFingerprint, expectedSourceStamps: edition.sourceStamps)
                workspace.activeTool = nil
            } catch { workspace.error = error.localizedDescription }
        } else if let reader = workspace.activeReader {
            reader.locator = entry.reference; reader.changeLocatorMode(false)
            reader.locator = entry.reference; reader.goToReference(); workspace.activeTool = nil
        }
    }
    @ViewBuilder private func verseTextContent(_ id: UUID) -> some View {
        if let row = verseText.rowsByID[id] {
            switch row.state {
            case .available, .partial:
                ForEach(Array(row.verses.enumerated()), id: \.offset) { _, verse in
                    Text(verse.text).textSelection(.enabled)
                }
                if row.state == .partial { Text(L("Algunos versículos del rango no aparecen en esta edición.")).font(.caption).foregroundStyle(.secondary) }
            case .missing: Text(L("Versículo ausente en esta edición.")).foregroundStyle(.secondary)
            case .unverified: Text(L("Versículo sin verificar en esta edición.")).foregroundStyle(.secondary)
            case .invalid: Text(L("Referencia no reconocida.")).foregroundStyle(.secondary)
            }
        }
    }
    private func canMoveVerse(_ offset: Int, index: Int) -> Bool {
        guard let selectedVerse, let position = personal.documents[index].verses.firstIndex(where: { $0.id == selectedVerse }) else { return false }
        return personal.documents[index].verses.indices.contains(position + offset)
    }
    private func moveVerse(_ offset: Int, index: Int) {
        guard let selectedVerse else { return }
        do { try StudyVerseOrganization.move(selectedVerse, by: offset, in: &personal.documents[index]) }
        catch { workspace.error = error.localizedDescription }
    }
}
