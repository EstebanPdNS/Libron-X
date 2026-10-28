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
    @RebuildViewState private var selectedVerse: UUID?
    @RebuildViewState private var verseReference = ""
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
            .onChange(of: personal.documents) { workspace.personalSearchDestination = nil; personal.scheduleSave() }
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
                    TextField(L("Título de la nota"), text: $personal.documents[index].notes[note].title).macInputStyle()
                    WorkspaceNoteEditor(note: personal.documents[index].notes[note]) { data in
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
            }
            ScrollViewReader { scroll in
            List(personal.documents[index].verses, selection: $selectedVerse) { verse in
                HStack {
                    Text(verse.reference); Spacer()
                    Button(L("Abrir")) { if let reader = workspace.activeReader { reader.locator = verse.reference; reader.changeLocatorMode(false); reader.locator = verse.reference; reader.goToReference(); workspace.activeTool = nil } }
                        .disabled(workspace.activeReader == nil)
                    Button { personal.documents[index].verses.removeAll { $0.id == verse.id } } label: { MacToolbarLabel(L("Eliminar versículo"), "trash") }
                }.tag(verse.id).id(verse.id)
            }
            .onAppear { if let selectedVerse { scroll.scrollTo(selectedVerse, anchor: .center) } }
            .onChange(of: selectedVerse) { if let selectedVerse { scroll.scrollTo(selectedVerse, anchor: .center) } }
            }
        }
    }
}
