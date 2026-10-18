import SwiftUI
import LibronixCore

struct WorkspaceDocumentsView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var personal: WorkspacePersonalState
    @RebuildViewState private var selectedNote: UUID?
    @RebuildViewState private var selectedVerse: UUID?
    @RebuildViewState private var verseReference = ""
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
                if let id = workspace.pendingNoteID { selectedNote = id; workspace.pendingNoteID = nil }
                applySearchNavigation()
            }
            .onChange(of: personal.documents) { workspace.personalSearchDestination = nil; personal.scheduleSave() }
            .onChange(of: personal.selectedDocumentID) { selectedNote = nil; selectedVerse = nil; applySearchNavigation() }
            .onChange(of: workspace.personalNavigationID) { applySearchNavigation() }
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
                List(personal.documents[index].notes, selection: $selectedNote) { note in Text(note.title).tag(note.id) }
                Button(L("Agregar nota")) {
                    var note = StudyNote(); note.sourceContentType = "text/plain"
                    personal.documents[index].notes.append(note); selectedNote = note.id
                }
            }.frame(minWidth: 150, idealWidth: 220)
            if let note = personal.documents[index].notes.firstIndex(where: { $0.id == selectedNote }) {
                VStack(alignment: .leading) {
                    TextField(L("Título de la nota"), text: $personal.documents[index].notes[note].title).macInputStyle()
                    if personal.documents[index].notes[note].sourceContentType == "text/html" {
                        ScrollView { Text(PersonalReferenceProjection.body(personal.documents[index].notes[note]).text).textSelection(.enabled) }
                        Button(L("Crear una nota editable con este texto")) {
                            var copy = StudyNote(title: personal.documents[index].notes[note].title)
                            copy.sourceContentType = "text/plain"; copy.sourceBody = NoteHTMLProjection.spans(personal.documents[index].notes[note].sourceBody).map(\.text).joined()
                            personal.documents[index].notes.append(copy); selectedNote = copy.id
                        }
                    } else { TextEditor(text: $personal.documents[index].notes[note].sourceBody).font(.body) }
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
                }.padding(8).frame(minWidth: 300)
            } else { Text(L("Selecciona una nota.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
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
