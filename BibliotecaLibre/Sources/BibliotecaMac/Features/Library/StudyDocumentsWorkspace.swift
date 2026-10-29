import AppKit
import LibronixCore
import SwiftUI

struct StudyDocumentsCatalog: View {
    @Bindable var model: LibraryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Documentos").font(.system(size: 28, design: .serif))
            Menu("Nuevo documento") {
                Button("Archivo de notas") { model.selectedDocumentID = model.store.documents.create(kind: .notebook, title: "Mis notas") }
                Button("Lista de versículos") { model.selectedDocumentID = model.store.documents.create(kind: .verseList, title: "Mis versículos") }
            }
            Button("Importar documento…") { model.store.documents.importDocument { model.selectedDocumentID = $0 } }
            List(selection: $model.selectedDocumentID) {
                ForEach(model.store.documents.documents) { document in
                    Label(document.title, systemImage: document.kind.usesNotes ? "note.text" : "list.bullet.rectangle")
                        .tag(document.id)
                }
            }.listStyle(.inset)
        }.padding(22)
    }
}

struct StudyDocumentsWorkspace: View {
    @Bindable var model: LibraryModel
    private var store: StudyDocumentsStore { model.store.documents }
    private var document: StudyDocument? { store.document(model.selectedDocumentID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let document {
                HStack {
                    TextField("Nombre del documento", text: Binding(get: { self.document?.title ?? "" }, set: { value in store.change(document.id) { $0.title = value } }))
                        .font(.system(size: 25, design: .serif)).textFieldStyle(.plain)
                    Button("Guardar") { store.save(document.id) }.disabled(!store.unsavedIDs.contains(document.id))
                    Button("Guardar copia…") { store.exportDocument(document.id) }
                }
                Text(store.unsavedIDs.contains(document.id) ? "Guardando cambios…" : "Guardado en tu Mac")
                    .font(.caption).foregroundStyle(.secondary)
                if document.kind.usesNotes { notebook(document) }
                else { verses(document) }
            } else {
                ContentUnavailableView("Tus documentos de estudio", systemImage: "note.text",
                    description: Text("Crea un archivo de notas o una lista de versículos, o importa un documento de Libronix."))
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.selectedDocumentID) { _, _ in
            if document?.notes.contains(where: { $0.id == model.selectedNoteID }) != true { model.selectedNoteID = document?.notes.first?.id }
        }
        .onAppear { if document?.notes.contains(where: { $0.id == model.selectedNoteID }) != true { model.selectedNoteID = document?.notes.first?.id } }
        .alert("El documento necesita atención", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Aceptar", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onDisappear { store.flush() }
    }
    private func notebook(_ document: StudyDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Nueva nota") {
                    let note = StudyNote(); store.change(document.id) { $0.notes.append(note) }; model.selectedNoteID = note.id
                }
                Button("Anotar lectura") { model.addStudyNote(selection: false) }.disabled(model.reader.currentLocation == nil)
                Button("Anotar selección") { model.addStudyNote(selection: true) }.disabled((model.reader.selectedTextRange?.length ?? 0) == 0)
            }.controlSize(.small)
            List(selection: $model.selectedNoteID) {
                ForEach(document.notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title).font(.headline)
                        Text(anchorTitle(note.anchor)).font(.caption).foregroundStyle(.secondary)
                    }.tag(note.id)
                }
            }.listStyle(.inset).frame(minHeight: 100, idealHeight: 140, maxHeight: 190)
            if let note = document.notes.first(where: { $0.id == model.selectedNoteID }) {
                TextField("Título de la nota", text: Binding(get: { self.document?.notes.first { $0.id == note.id }?.title ?? "" }, set: { value in store.changeNote(document.id, noteID: note.id) { $0.title = value } }))
                    .textFieldStyle(.roundedBorder)
                NoteRichTextEditor(note: note) { data in store.changeNote(document.id, noteID: note.id) { $0.editedRTF = data } }
                    .frame(minHeight: 160, maxHeight: .infinity)
                HStack {
                    if note.anchor.location != nil || note.anchor.kind == .legacySelection {
                        Button("Abrir lectura vinculada") { model.navigateNote(note, documentID: document.id) }.disabled(model.isResolvingOriginalDestination)
                    }
                    if note.anchor.kind == .legacyReference {
                        Text("Ancla original conservada; su traducción al lector nativo sigue en desarrollo.").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isResolvingOriginalDestination { ProgressView().controlSize(.small); Text("Comprobando la posición…").font(.caption) }
                    Spacer()
                    if let author = note.sourceAttributes["author"], !author.isEmpty { Text(author).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func verses(_ document: StudyDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Añadir lectura actual") {
                    guard let location = model.reader.currentLocation else { return }
                    let entry = StudyVerseEntry(reference: location.reference ?? model.reader.currentTitle, location: location)
                    store.change(document.id) { $0.verses.append(entry) }
                }.disabled(model.reader.currentLocation == nil)
                Picker("Presentación", selection: Binding(get: { self.document?.presentation ?? "ReferencesOnly" }, set: { value in store.change(document.id) { $0.presentation = value } })) {
                    Text("Referencias").tag("ReferencesOnly")
                    Text("Referencias y texto").tag("BothTwoColumns")
                }.frame(width: 220)
            }
            List {
                ForEach(Array(document.verses.enumerated()), id: \.element.id) { index, entry in
                    HStack {
                        Text(entry.reference).textSelection(.enabled)
                        Spacer()
                        if document.presentation == "BothTwoColumns" {
                            Text("Texto pendiente de resolución").font(.caption).foregroundStyle(.secondary)
                        }
                        if let location = entry.location { Button("Abrir") { model.navigate(location) }.buttonStyle(.borderless) }
                        Button { store.change(document.id) { $0.verses.removeAll { $0.id == entry.id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Quitar referencia \(index + 1)")
                    }
                }.onMove { indices, offset in store.change(document.id) { $0.verses.move(fromOffsets: indices, toOffset: offset) } }
            }.listStyle(.inset)
            if document.sourceXML != nil {
                Text("Se conservan el orden, rangos y versiones del documento original. La resolución de sus referencias y la presentación de texto bíblico siguen en desarrollo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func anchorTitle(_ anchor: StudyNoteAnchor) -> String {
        switch anchor.kind {
        case .general: "Nota general"
        case .nativeSelection: "Selección en \(anchor.location?.reference ?? "el artículo")"
        case .nativeReference: anchor.location?.reference ?? "Lectura vinculada"
        case .legacySelection: "Selección de Libronix"
        case .legacyReference: anchor.legacyAttributes["reference"] ?? "Referencia de Libronix"
        }
    }
}

struct NoteRichTextEditor: NSViewRepresentable {
    let note: StudyNote
    let changed: (Data) -> Void
    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteID: UUID?
        var sourceData: Data?
        var applying = false
        var changed: ((Data) -> Void)?
        func textDidChange(_ notification: Notification) {
            guard !applying, let text = notification.object as? NSTextView, let storage = text.textStorage,
                  let data = try? storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return }
            sourceData = data; changed?(data)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = NSTextView(frame: .zero)
        editor.isEditable = true; editor.isSelectable = true; editor.isRichText = true; editor.allowsUndo = true
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Contenido de la nota"); editor.delegate = context.coordinator
        scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator; coordinator.changed = changed
        guard coordinator.noteID != note.id || coordinator.sourceData != note.editedRTF else { return }
        coordinator.applying = true; defer { coordinator.applying = false }
        let previous = editor.selectedRange(), changedNote = coordinator.noteID != note.id
        editor.textStorage?.setAttributedString(Self.attributed(note))
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor]
        if changedNote { editor.undoManager?.removeAllActions(); editor.setSelectedRange(NSRange(location: 0, length: 0)) }
        else if NSMaxRange(previous) <= editor.string.utf16.count { editor.setSelectedRange(previous) }
        coordinator.noteID = note.id; coordinator.sourceData = note.editedRTF
    }
    static func attributed(_ note: StudyNote) -> NSAttributedString {
        if let data = note.editedRTF, let native = NSAttributedString(rtf: data, documentAttributes: nil) { return native }
        let spans = note.sourceContentType == "text/html" ? NoteHTMLProjection.spans(note.sourceBody) : [NoteTextSpan(text: note.sourceBody)]
        let result = NSMutableAttributedString(string: "")
        for span in spans {
            var font = NSFont.systemFont(ofSize: 16)
            if span.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if span.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            if span.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if span.strikeout { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let reference = span.reference { attrs[.foregroundColor] = NSColor.linkColor; attrs[.toolTip] = reference }
            result.append(NSAttributedString(string: span.text, attributes: attrs))
        }
        return result
    }
}
