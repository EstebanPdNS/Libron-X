import SwiftUI
import LibronixCore

struct PreviousDocumentsView: View {
    @Bindable var personal: WorkspacePersonalState
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var report = PersonalDocumentHistory.Report()
    @RebuildViewState private var selection: String?
    @RebuildViewState private var offset = 0
    @RebuildViewState private var filter = ""
    @RebuildViewState private var error: String?
    private var versions: [PersonalDocumentHistory.Version] {
        report.versions.filter { filter.isEmpty || $0.document.title.localizedStandardContains(filter) }
    }
    private var selected: PersonalDocumentHistory.Version? { versions.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Historial de documentos") { dismiss() }
            Text(L("Las revisiones se conservan al guardar cambios. Recuperar crea una copia sin reemplazar el documento actual."))
                .font(.caption).foregroundStyle(.secondary)
            TextField(L("Filtrar documentos"), text: $filter).macInputStyle()
            HSplitView {
                List(versions, selection: $selection) { version in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(version.document.title, systemImage: version.document.kind.symbol)
                            .lineLimit(2)
                        if let date = version.date { Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4).tag(version.id)
                }.frame(minWidth: 220, idealWidth: 250)
                    .overlay {
                        if versions.isEmpty && error == nil { Text(L("No hay versiones guardadas en esta página.")).foregroundStyle(.secondary).padding().allowsHitTesting(false) }
                    }
                ScrollView {
                    if let selected {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text(selected.document.title).font(.headline)
                            if let metadata = selected.document.sermon { SermonMetadataSummary(metadata: metadata) }
                            Text(L("La vista previa muestra texto; la copia recuperada conserva el documento completo."))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(selected.document.notes) { note in
                                Text(note.title).font(.headline)
                                switch Result(catching: { try NoteRichTextCodec.attributed(note) }) {
                                case .success(let body): Text(BibleCopyPreview.text(body)).textSelection(.enabled)
                                case .failure(let error): Text(L(error.localizedDescription)).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                            ForEach(selected.document.verses) { Text($0.reference).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } else { Text(L("Selecciona una versión para revisarla.")).foregroundStyle(.secondary).padding() }
                }.frame(minWidth: 280).macEditorSurface().padding(.leading, 12)
            }
            if report.unreadableSnapshots > 0 {
                Text(LF("No se pudieron leer {count} copias del historial; se han conservado sus archivos.", ["count": String(report.unreadableSnapshots)]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(L(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 12) {
                Button { offset -= 20; load() } label: { Label(L("Anterior"), systemImage: "chevron.backward") }.disabled(offset == 0)
                Button { offset += 20; load() } label: { Label(L("Siguiente"), systemImage: "chevron.forward") }.disabled(!report.hasMore)
                Spacer()
                Button(L("Recuperar como copia")) { recover() }.disabled(selected == nil)
            }
        }.padding(16).frame(width: 720, height: 500).modifier(MacPanelControlPresentation()).onAppear(perform: load)
    }
    private func load() {
        do { report = try personal.documentHistory(offset: offset); selection = nil; error = nil }
        catch { report = .init(); self.error = error.localizedDescription }
    }
    private func recover() {
        guard let selected else { return }
        do {
            try personal.recoverDocumentVersion(selected, title: LF("{title} (recuperado)", ["title": selected.document.title]))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
