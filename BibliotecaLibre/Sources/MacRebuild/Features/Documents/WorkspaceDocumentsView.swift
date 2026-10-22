import SwiftUI
import LibronixCore

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
            .onChange(of: personal.selectedDocumentID) { selectedNote = nil; selectedVerse = nil; applySearchNavigation() }
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
            VStack {
                List(personal.documents[index].notes, selection: $selectedNotes) { note in Text(note.title).tag(note.id) }
                    .accessibilityIdentifier("notes.list")
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        Button(L("Renombrar nota")) { requestRename(ids, index: index) }.disabled(ids.count != 1)
                        Button(L("Borrar notas"), role: .destructive) { requestDeletion(ids, index: index) }.disabled(ids.isEmpty)
                    }
                    .onDeleteCommand { requestDeletion(selectedNotes, index: index) }
                Button(L("Agregar nota")) {
                    var note = StudyNote(); note.sourceContentType = "text/plain"
                    personal.documents[index].notes.append(note); selectedNote = note.id
                }
            }.frame(minWidth: 150, idealWidth: 220)
            VStack(alignment: .leading) {
                if let note = personal.documents[index].notes.firstIndex(where: { $0.id == selectedNote }) {
                    TextField(L("Título de la nota"), text: $personal.documents[index].notes[note].title).macInputStyle()
                    if personal.documents[index].notes[note].sourceContentType == "text/html" {
                        ScrollView { Text(PersonalReferenceProjection.body(personal.documents[index].notes[note]).text).textSelection(.enabled) }
                        Button(L("Crear una nota editable con este texto")) {
                            var copy = StudyNote(title: personal.documents[index].notes[note].title)
                            copy.sourceContentType = "text/plain"; copy.sourceBody = NoteHTMLProjection.spans(personal.documents[index].notes[note].sourceBody).map(\.text).joined()
                            personal.documents[index].notes.append(copy); selectedNote = copy.id
                        }
                    } else { TextEditor(text: $personal.documents[index].notes[note].sourceBody).font(.body).focused($noteBodyFocused) }
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
            }.padding(8).frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
