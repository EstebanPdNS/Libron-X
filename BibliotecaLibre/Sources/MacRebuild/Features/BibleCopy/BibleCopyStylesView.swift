import SwiftUI
import LibronixCore

struct BibleCopyStylesView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var personal: WorkspacePersonalState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var original: BibleCopyOutputStyle?
    @RebuildViewState private var page = 0
    @RebuildViewState private var draft = BibleCopyOutputStyle(name: "")
    @RebuildViewState private var editingNew = false
    @RebuildViewState private var pendingID: UUID?
    @RebuildViewState private var pendingClose = false
    @RebuildViewState private var confirmChanges = false
    @RebuildViewState private var deleting = false
    @RebuildViewState private var error: String?
    private var selected: BibleCopyOutputStyle? { original }
    private var readOnly: Bool { !editingNew && selected?.preset != nil }
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
                if layoutDirection == .rightToLeft { editorPane; templateList }
                else { templateList; editorPane }
            }
            if let message = error ?? personal.bibleCopyLoadError { Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(16).frame(width: 760, height: 600).modifier(MacPanelControlPresentation())
            .interactiveDismissDisabled().onExitCommand { requestClose() }
            .onAppear { load(personal.bibleCopyState.selectedStyleID); workspace.copyStyleCloseGuard = { if dirty { requestClose(); return false }; return true } }
            .onChange(of: draft.bibleTextOnly) { if !draft.bibleTextOnly { draft.paragraphs = .sourceParagraphs } }
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
    private var templateList: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: selection) {
                Section(L("Plantillas incluidas")) {
                    ForEach(BibleCopyOutputStyle.defaults) { style in
                        Label(L(style.name), systemImage: "doc.text").tag(style.id)
                    }
                }
                Section(L("Mis plantillas")) {
                    ForEach(personal.bibleCopyState.customStyles) { style in
                        Label(style.name, systemImage: "doc.text").tag(style.id)
                    }
                }
            }.listStyle(.inset)
            HStack(spacing: 8) {
                Button(action: create) { Label(L("Nueva plantilla"), systemImage: "plus").labelStyle(.iconOnly) }.help(L("Nueva plantilla")).disabled(dirty)
                Button(action: duplicate) { Label(L("Duplicar"), systemImage: "plus.square.on.square").labelStyle(.iconOnly) }.help(L("Duplicar")).disabled(dirty || selected == nil)
                Button { deleting = true } label: { Label(L("Eliminar"), systemImage: "trash").labelStyle(.iconOnly) }.help(L("Eliminar")).disabled(editingNew || selected == nil || dirty || readOnly)
            }
        }.frame(minWidth: 210, idealWidth: 230, maxWidth: 260).padding(.horizontal, 8)
    }
    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editingNew || selected != nil {
                if readOnly { Text(L(draft.name)).font(.headline).padding(.vertical, 7) }
                else { TextField(L("Nombre de plantilla"), text: $draft.name).macInputStyle() }
                Picker(L("Opciones de plantilla"), selection: $page) {
                    Text(L("Texto")).tag(0); Text(L("Formato")).tag(1); Text(L("Idiomas")).tag(2)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(L("Opciones de plantilla"))
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch page {
                        case 0:
                            BibleCopyTemplateEditor(title: "Antes del pasaje", template: $draft.beforePassage)
                            BibleCopyTemplateEditor(title: "Antes de cada versículo", template: $draft.beforeVerse)
                            BibleCopyTemplateEditor(title: "Después de cada versículo", template: $draft.afterVerse)
                            BibleCopyTemplateEditor(title: "Después del pasaje", template: $draft.afterPassage)
                            Text(L("^P pasaje · ^R referencia · ^B libro · ^c capítulo · ^v versículo · ^a abreviatura · ^n salto de línea · ^^ acento circunflejo"))
                                .font(.caption).foregroundStyle(.secondary)
                        case 1:
                            Toggle(L("Formato de caracteres"), isOn: $draft.characterFormatting)
                            Toggle(L("Formato de párrafos"), isOn: $draft.paragraphFormatting)
                            Toggle(L("Palabras de Jesús en rojo"), isOn: $draft.redLetter)
                            Toggle(L("Solo texto bíblico"), isOn: $draft.bibleTextOnly)
                            Toggle(L("Cita bibliográfica"), isOn: $draft.citation)
                            Toggle(L("Notas al pie"), isOn: $draft.copyFootnotes)
                            Text(L("Párrafos")).font(.caption).foregroundStyle(.secondary)
                            MacSelectionMenu(L("Párrafos"), value: draft.paragraphs.localizedTitle, selection: $draft.paragraphs) {
                                ForEach(BibleCopyParagraphPolicy.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                            }.disabled(!draft.bibleTextOnly)
                        default:
                            Text(L("Griego")).font(.caption).foregroundStyle(.secondary)
                            MacSelectionMenu(L("Griego"), value: draft.greek.localizedTitle, selection: $draft.greek) {
                                Text(L("Texto original")).tag(BibleCopyLanguageRendering.unicode)
                                Text(L("Transliteración")).tag(BibleCopyLanguageRendering.transliterated)
                            }
                            Text(L("Hebreo")).font(.caption).foregroundStyle(.secondary)
                            MacSelectionMenu(L("Hebreo"), value: draft.hebrew.localizedTitle, selection: $draft.hebrew) {
                                Text(L("Texto original")).tag(BibleCopyLanguageRendering.unicode)
                                Text(L("Transliteración")).tag(BibleCopyLanguageRendering.transliterated)
                                if draft.hebrew != .unicode && draft.hebrew != .transliterated {
                                    Text(draft.hebrew.localizedTitle).tag(draft.hebrew).disabled(true)
                                }
                            }
                            if draft.hebrew != .unicode && draft.hebrew != .transliterated {
                                Text(L("Selecciona texto original o transliteración para copiar este estilo hebreo heredado.")).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(L("Marcas hebreas")).font(.caption).foregroundStyle(.secondary)
                            MacSelectionMenu(L("Marcas hebreas"), value: draft.hebrewLetters.localizedTitle, selection: $draft.hebrewLetters) {
                                ForEach(BibleCopyHebrewLetters.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).disabled(readOnly)
                }
                if readOnly { Text(L("Duplica una plantilla incluida para editarla.")).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 12) {
                    Spacer()
                    Button(L("Guardar plantilla")) { _ = save() }.disabled(!dirty || readOnly || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L("Usar plantilla")) { use() }.disabled(dirty || selected == nil)
                }
            } else { Text(L("Selecciona una plantilla o crea una nueva.")).foregroundStyle(.secondary); Spacer() }
        }.frame(minWidth: 420).padding(.horizontal, 16)
    }
    private func load(_ id: UUID?) {
        selectedID = id; editingNew = false
        original = personal.bibleCopyState.styles.first { $0.id == id }
        draft = original ?? BibleCopyOutputStyle(name: "")
        error = nil
    }
    private func create() { page = 0; selectedID = nil; original = nil; draft = BibleCopyOutputStyle(name: ""); editingNew = true; error = nil }
    private func duplicate() {
        guard let selected else { return }
        draft = selected; draft.id = UUID(); draft.name = (selected.preset == nil ? selected.name : L(selected.name)) + " — " + L("Copia"); draft.preset = nil
        selectedID = nil; original = nil; editingNew = true; error = nil
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
                state.selectedStyleID = value.id
            }
            selectedID = value.id; self.original = value; editingNew = false; draft = value; error = nil; return true
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
    private func use() {
        guard let selected else { return }
        do {
            try personal.editBibleCopyState { $0.selectedStyleID = selected.id }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func requestClose() { if dirty { pendingClose = true; confirmChanges = true } else { dismiss() } }
    private func finishPending() { if pendingClose { dismiss() } else { load(pendingID) } }
}

private struct BibleCopyTemplateEditor: View {
    let title: String
    @Binding var template: BibleCopyOutputTemplate
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(L(title)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Group {
                    Toggle(isOn: $template.bold) { Label(L("Negrita"), systemImage: "bold") }.accessibilityLabel(L(title) + ": " + L("Negrita"))
                    Toggle(isOn: $template.italic) { Label(L("Cursiva"), systemImage: "italic") }.accessibilityLabel(L(title) + ": " + L("Cursiva"))
                    Toggle(isOn: $template.underline) { Label(L("Subrayado"), systemImage: "underline") }.accessibilityLabel(L(title) + ": " + L("Subrayado"))
                    Toggle(isOn: Binding(get: { template.superscript }, set: { template.superscript = $0; if $0 { template.subscriptText = false } })) { Label(L("Superíndice"), systemImage: "textformat.superscript") }.accessibilityLabel(L(title) + ": " + L("Superíndice"))
                    Toggle(isOn: Binding(get: { template.subscriptText }, set: { template.subscriptText = $0; if $0 { template.superscript = false } })) { Label(L("Subíndice"), systemImage: "textformat.subscript") }.accessibilityLabel(L(title) + ": " + L("Subíndice"))
                }.toggleStyle(.button).labelStyle(.iconOnly).controlSize(.small)
            }
            TextField(L(title), text: $template.pattern).macInputStyle()
        }
    }
}
@MainActor extension BibleCopyParagraphPolicy {
    var localizedTitle: String { switch self { case .perVerse: L("Por versículo"); case .sourceParagraphs: L("Del original"); case .perPassage: L("Un solo párrafo") } }
}
@MainActor extension BibleCopyLanguageRendering {
    var localizedTitle: String { switch self { case .unicode: L("Texto original"); case .transliterated: L("Transliteración"); case .hebraicaII: "Hebraica II"; case .michiganClaremont: "Michigan–Claremont" } }
}
@MainActor extension BibleCopyHebrewLetters {
    var localizedTitle: String { switch self { case .full: L("Todas las marcas"); case .consonantsAndVowels: L("Sin cantilación"); case .consonantsOnly: L("Solo consonantes") } }
}
