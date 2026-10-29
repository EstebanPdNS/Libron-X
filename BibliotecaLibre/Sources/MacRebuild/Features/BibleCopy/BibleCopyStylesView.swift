import SwiftUI
import LibronixCore

struct BibleCopyStylesView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var personal: WorkspacePersonalState
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var draft = BibleCopyOutputStyle(name: "")
    @RebuildViewState private var editingNew = false
    @RebuildViewState private var pendingID: UUID?
    @RebuildViewState private var pendingClose = false
    @RebuildViewState private var confirmChanges = false
    @RebuildViewState private var deleting = false
    @RebuildViewState private var error: String?
    private var selected: BibleCopyOutputStyle? { personal.bibleCopyState.customStyles.first { $0.id == selectedID } }
    private var dirty: Bool { editingNew || (selected != nil && selected != draft) }
    private var selection: Binding<UUID?> {
        Binding(get: { selectedID }, set: { id in
            guard id != selectedID else { return }
            if dirty { pendingID = id; pendingClose = false; confirmChanges = true }
            else { load(id) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Plantillas de copia") { requestClose() }
            HSplitView {
                List(personal.bibleCopyState.customStyles, selection: selection) { style in Text(style.name).tag(style.id) }
                    .frame(minWidth: 190)
                    .overlay { if personal.bibleCopyState.customStyles.isEmpty { Text(L("No hay plantillas guardadas.")).foregroundStyle(.secondary).allowsHitTesting(false) } }
                VStack(alignment: .leading, spacing: 10) {
                    if editingNew || selected != nil {
                        ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                        TextField(L("Nombre de plantilla"), text: $draft.name).macInputStyle()
                        Text(L("Antes del pasaje")); TextField(L("Antes del pasaje"), text: $draft.beforePassage.pattern).macInputStyle()
                        Text(L("Antes de cada versículo")); TextField(L("Antes de cada versículo"), text: $draft.beforeVerse.pattern).macInputStyle()
                        Text(L("Después de cada versículo")); TextField(L("Después de cada versículo"), text: $draft.afterVerse.pattern).macInputStyle()
                        Text(L("Después del pasaje")); TextField(L("Después del pasaje"), text: $draft.afterPassage.pattern).macInputStyle()
                        Picker(L("Griego"), selection: $draft.greek) {
                            Text(L("Texto original")).tag(BibleCopyLanguageRendering.unicode)
                            Text(L("Transliteración")).tag(BibleCopyLanguageRendering.transliterated)
                        }
                        Picker(L("Hebreo"), selection: $draft.hebrew) {
                            Text(L("Texto original")).tag(BibleCopyLanguageRendering.unicode)
                            Text(L("Transliteración")).tag(BibleCopyLanguageRendering.transliterated)
                        }
                        Picker(L("Marcas hebreas"), selection: $draft.hebrewLetters) {
                            Text(L("Todas las marcas")).tag(BibleCopyHebrewLetters.full)
                            Text(L("Sin cantilación")).tag(BibleCopyHebrewLetters.consonantsAndVowels)
                            Text(L("Solo consonantes")).tag(BibleCopyHebrewLetters.consonantsOnly)
                        }
                        Text(L("^P pasaje · ^R referencia · ^B libro · ^c capítulo · ^v versículo · ^a abreviatura · ^n salto de línea · ^^ acento circunflejo"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L("Usa Vista previa en Copiar versículos para comprobar el resultado con un pasaje."))
                            .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            Button(L("Guardar plantilla")) { _ = save() }.disabled(!dirty)
                            Button(L("Duplicar")) { duplicate() }.disabled(dirty || selected == nil)
                            Button(L("Eliminar")) { deleting = true }.disabled(editingNew || selected == nil || dirty)
                        }
                    } else { Text(L("Selecciona una plantilla o crea una nueva.")).foregroundStyle(.secondary); Spacer() }
                }.frame(minWidth: 320).padding(.leading, 12)
            }
            if let message = error ?? personal.bibleCopyLoadError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button(L("Nueva plantilla")) { create() }.disabled(dirty); Spacer() }
        }.padding(16).frame(width: 760, height: 600).modifier(MacPanelControlPresentation())
            .interactiveDismissDisabled().onExitCommand { requestClose() }
            .onAppear { workspace.copyStyleCloseGuard = { if dirty { requestClose(); return false }; return true } }
            .onDisappear { workspace.copyStyleCloseGuard = nil }
            .alert(L("Cambios sin guardar"), isPresented: $confirmChanges) {
                Button(L("Guardar")) { if save() { finishPending() } }
                Button(L("Descartar"), role: .destructive) { finishPending() }
                Button(L("Cancelar"), role: .cancel) { }
            } message: { Text(L("Guarda la plantilla antes de continuar.")) }
            .alert(L("Eliminar plantilla"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { remove() }
            } message: { Text(L("Se eliminará esta plantilla de copia.")) }
    }
    private func load(_ id: UUID?) {
        selectedID = id; editingNew = false
        draft = personal.bibleCopyState.customStyles.first { $0.id == id } ?? BibleCopyOutputStyle(name: "")
        error = nil
    }
    private func create() { selectedID = nil; draft = BibleCopyOutputStyle(name: ""); editingNew = true; error = nil }
    private func duplicate() {
        guard let selected else { return }
        draft = selected; draft.id = UUID(); draft.name += " — " + L("Copia"); draft.preset = nil
        selectedID = nil; editingNew = true; error = nil
    }
    @discardableResult private func save() -> Bool {
        let original = selected
        var value = draft; value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try personal.editBibleCopyState { state in
                if editingNew { state.customStyles.append(value) }
                else {
                    guard let original, let index = state.customStyles.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                    state.customStyles[index] = value
                }
            }
            selectedID = value.id; editingNew = false; draft = value; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func remove() {
        guard let original = selected else { return }
        do {
            try personal.editBibleCopyState { state in
                guard let index = state.customStyles.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                state.customStyles.remove(at: index)
                if state.selectedStyleID == original.id { state.selectedStyleID = BibleCopyOutputStyle.defaults[1].id }
            }
            load(nil)
        } catch { self.error = error.localizedDescription }
    }
    private func requestClose() { if dirty { pendingClose = true; confirmChanges = true } else { dismiss() } }
    private func finishPending() { if pendingClose { dismiss() } else { load(pendingID) } }
}
