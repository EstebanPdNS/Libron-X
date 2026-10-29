import SwiftUI
import LibronixCore

struct ResearchInboxView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var personal: WorkspacePersonalState
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var note = ""
    @RebuildViewState private var deleting = false
    @RebuildViewState private var changingSelection = false
    @RebuildViewState private var pendingID: UUID?
    @RebuildViewState private var error: String?
    private var selected: ResearchExcerpt? { personal.researchInbox.excerpts.first { $0.id == selectedID } }
    private var selection: Binding<UUID?> {
        Binding(get: { selectedID }, set: { next in
            guard next != selectedID else { return }
            if let selected, selected.note != note { pendingID = next; changingSelection = true }
            else { selectedID = next }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Selecciona texto en un recurso y usa Herramientas para guardarlo aquí."))
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(personal.researchInbox.excerpts, selection: selection) { excerpt in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(excerpt.sourceTitle).lineLimit(1)
                        Text(excerpt.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.tag(excerpt.id)
                }.frame(minWidth: 220)
                    .overlay { if personal.researchInbox.excerpts.isEmpty { Text(L("No hay extractos guardados.")).foregroundStyle(.secondary).allowsHitTesting(false) } }
                VStack(alignment: .leading, spacing: 12) {
                    if let excerpt = selected {
                        Text(excerpt.sourceTitle).font(.headline)
                        if let reference = excerpt.location.reference { Text(reference).font(.caption).foregroundStyle(.secondary) }
                        ScrollView { Text(excerpt.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(minHeight: 80, maxHeight: 180)
                        Text(L("Comentario"))
                        TextEditor(text: $note).scrollContentBackground(.hidden).padding(8).frame(minHeight: 100)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
                        HStack {
                            Button(L("Guardar comentario")) { saveNote() }.disabled(note == excerpt.note)
                            Button(L("Abrir origen")) { workspace.openResearchExcerpt(excerpt) }
                            Button(L("Eliminar")) { deleting = true }
                        }
                    } else { Text(L("Selecciona un extracto.")).foregroundStyle(.secondary); Spacer() }
                }.frame(minWidth: 300).padding(.leading, 12)
            }
            if let message = error ?? personal.researchInboxLoadError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(16)
            .onChange(of: selectedID) { note = selected?.note ?? ""; error = nil }
            .onAppear {
                if selectedID == nil { selectedID = personal.researchInbox.excerpts.first?.id }
                workspace.researchDraftSaver = { saveDraftIfNeeded() }
            }
            .onDisappear { workspace.researchDraftSaver = nil }
            .onExitCommand { workspace.closeActiveTool() }
            .alert(L("Eliminar extracto"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { remove() }
            } message: { Text(L("Se eliminará este extracto de la bandeja.")) }
            .alert(L("Comentario sin guardar"), isPresented: $changingSelection) {
                Button(L("Guardar")) { if saveNote() { selectedID = pendingID } }
                Button(L("Descartar"), role: .destructive) { selectedID = pendingID }
                Button(L("Cancelar"), role: .cancel) { }
            } message: { Text(L("Guarda el comentario antes de cambiar de extracto.")) }
    }
    @discardableResult private func saveNote() -> Bool {
        guard let original = selected else { return false }
        var changed = original; changed.note = note
        do {
            try personal.editResearchInbox { state in
                guard let index = state.excerpts.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                state.excerpts[index] = changed
            }
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func saveDraftIfNeeded() -> Bool {
        guard let selected, note != selected.note else { return true }
        return saveNote()
    }
    private func remove() {
        guard let original = selected else { return }
        do {
            try personal.editResearchInbox { state in
                guard let index = state.excerpts.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                state.excerpts.remove(at: index)
            }
            selectedID = personal.researchInbox.excerpts.first?.id; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
