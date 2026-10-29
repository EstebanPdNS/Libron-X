import SwiftUI
import LibronixCore

struct PreviousDocumentsView: View {
    @Bindable var personal: WorkspacePersonalState
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var documents: [StudyDocument] = []
    @RebuildViewState private var selection: UUID?
    @RebuildViewState private var error: String?
    private var selected: StudyDocument? { documents.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Recuperar versión anterior") { dismiss() }
            Text(L("Se muestra la copia anterior de los datos personales. La recuperación crea un documento nuevo."))
                .font(.caption).foregroundStyle(.secondary)
            List(documents, selection: $selection) { document in
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                    Text(L(document.kind == .notebook ? "Archivo de notas" : "Lista de versículos"))
                        .font(.caption).foregroundStyle(.secondary)
                }.tag(document.id)
            }.overlay {
                if documents.isEmpty && error == nil { Text(L("No hay documentos en la copia anterior.")).foregroundStyle(.secondary) }
            }
            if let error { Text(L(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Recuperar como copia")) { recover() }.disabled(selected == nil) }
        }.padding(16).frame(width: 600, height: 450).modifier(MacPanelControlPresentation())
            .onAppear {
                do { documents = try personal.previousDocuments() }
                catch { self.error = error.localizedDescription }
            }
    }
    private func recover() {
        guard let selected else { return }
        do {
            try personal.recoverPreviousDocument(selected, title: LF("{title} (recuperado)", ["title": selected.title]))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
