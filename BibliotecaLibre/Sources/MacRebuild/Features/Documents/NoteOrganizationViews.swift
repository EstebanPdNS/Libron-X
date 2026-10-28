import SwiftUI
import LibronixCore

struct NoteMoveView: View {
    let personal: WorkspacePersonalState
    let sourceID: UUID
    let ids: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var destinationID: UUID?
    @RebuildViewState private var parentID: UUID?
    @RebuildViewState private var error: String?
    private var parents: [StudyNoteOutlineEntry] {
        guard let document = personal.documents.first(where: { $0.id == destinationID }) else { return [] }
        let excluded = destinationID == sourceID ? (try? StudyNoteOrganization.subtree(ids, in: document.notes)) ?? ids : []
        return ((try? StudyNoteOrganization.outline(document.notes)) ?? []).filter { !excluded.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacToolHeader(title: "Mover notas") { dismiss() }
            Picker(L("Cuaderno de destino"), selection: $destinationID) {
                Text(L("Selecciona un documento")).tag(Optional<UUID>.none)
                ForEach(personal.documents.filter { $0.kind == .notebook }) { Text($0.title).tag(Optional($0.id)) }
            }
            Picker(L("Nota superior"), selection: $parentID) {
                Text(L("Nivel principal")).tag(Optional<UUID>.none)
                ForEach(parents) { entry in Text(String(repeating: "  ", count: min(entry.depth, 8)) + entry.note.title).tag(Optional(entry.id)) }
            }
            Text(L("Las subnotas se trasladan junto con sus notas superiores.")).font(.caption).foregroundStyle(.secondary)
            if let error { Text(L(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("Mover")) {
                    guard let destinationID else { return }
                    do { try personal.moveNotes(ids, from: sourceID, to: destinationID, parentID: parentID); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(destinationID == nil)
            }
        }.padding(20).frame(width: 500).modifier(MacPanelControlPresentation())
            .onAppear { destinationID = sourceID }
            .onChange(of: destinationID) { parentID = nil; error = nil }
    }
}

struct NotePropertiesView: View {
    let personal: WorkspacePersonalState
    let documentID: UUID
    let note: StudyNote
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var author = ""
    @RebuildViewState private var kind = ""
    @RebuildViewState private var style = ""
    @RebuildViewState private var tags = ""
    @RebuildViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Propiedades de la nota") { dismiss() }
            property("Autor", text: $author)
            property("Tipo", text: $kind)
            property("Estilo", text: $style)
            property("Etiquetas", text: $tags)
            if let origin = note.origin { Text(L("Origen") + ": " + origin.documentTitle).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(L(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("Guardar")) {
                    var values = note.properties ?? [:]
                    values["author"] = author; values["type"] = kind; values["style"] = style; values["tags"] = tags
                    do { try personal.setNoteProperties(note.id, in: documentID, values: values); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.padding(20).frame(width: 480).modifier(MacPanelControlPresentation())
            .onAppear {
                let values = note.sourceAttributes.merging(note.properties ?? [:], uniquingKeysWith: { _, native in native })
                author = values["author"] ?? ""; kind = values["type"] ?? ""; style = values["style"] ?? ""; tags = values["tags"] ?? ""
            }
    }
    private func property(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.caption).foregroundStyle(.secondary)
            TextField(L(title), text: text).macInputStyle()
        }
    }
}
