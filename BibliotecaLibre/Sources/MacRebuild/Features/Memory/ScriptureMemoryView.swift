import SwiftUI
import LibronixCore

private struct MemoryEdit: Identifiable {
    let id = UUID()
    let original: ScriptureMemoryCard?
}
struct ScriptureMemoryView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var personal: WorkspacePersonalState
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var editing: MemoryEdit?
    @RebuildViewState private var practice: ScriptureMemoryCard?
    @RebuildViewState private var deleting = false
    @RebuildViewState private var error: String?
    private var selected: ScriptureMemoryCard? { personal.scriptureMemory.cards.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(personal.scriptureMemory.cards, selection: $selectedID) { card in
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.reference).font(.headline)
                    Text(LF("Intentos: {attempts} · Correctos: {correct}", ["attempts": String(card.attempts), "correct": String(card.correct)]))
                        .font(.caption).foregroundStyle(.secondary)
                }.tag(card.id)
            }.overlay {
                if personal.scriptureMemory.cards.isEmpty { Text(L("No hay pasajes para practicar.")).foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            if let selected, !selected.source.isEmpty { Text(selected.source).font(.caption).foregroundStyle(.secondary) }
            if let error = error ?? personal.scriptureMemoryLoadError { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            MacReaderToolbarSurface {
                HStack {
                    MacReaderControlGroup {
                        MacToolbarButton("Añadir pasaje", "plus") { editing = .init(original: nil) }
                        MacToolbarButton("Editar pasaje", "pencil") { if let selected { editing = .init(original: selected) } }.disabled(selected == nil)
                        MacToolbarButton("Eliminar pasaje", "trash") { deleting = true }.disabled(selected == nil)
                    }
                    Spacer()
                    Button(L("Practicar")) { practice = selected }.disabled(selected == nil)
                }
            }
        }.padding(16)
            .sheet(item: $editing) { value in
                MemoryEditor(workspace: workspace, personal: personal, original: value.original) { selectedID = $0 }.modifier(AppInterfaceLanguage())
            }
            .sheet(item: $practice) { card in MemoryPractice(personal: personal, original: card).modifier(AppInterfaceLanguage()) }
            .alert(L("Eliminar pasaje"), isPresented: $deleting) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Eliminar"), role: .destructive) { remove() }
            } message: { Text(L("Se eliminará este ejercicio y su progreso.")) }
    }
    private func remove() {
        guard let original = selected else { return }
        do {
            try personal.editScriptureMemory { state in
                guard let index = state.cards.firstIndex(of: original) else { throw PersonalStateError.concurrentChange }
                state.cards.remove(at: index)
            }
            selectedID = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
private struct MemoryEditor: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var personal: WorkspacePersonalState
    let original: ScriptureMemoryCard?
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var reference = ""
    @RebuildViewState private var passage = ""
    @RebuildViewState private var source = ""
    @RebuildViewState private var resourceID = ""
    @RebuildViewState private var loading = false
    @RebuildViewState private var task: Task<Void, Never>?
    @RebuildViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: original == nil ? "Añadir pasaje" : "Editar pasaje") { dismiss() }
            TextField(L("Referencia"), text: $reference).macInputStyle()
            TextField(L("Fuente o versión"), text: $source).macInputStyle().disabled(loading)
            HStack {
                Picker(L("Biblia"), selection: $resourceID) {
                    Text(L("Selecciona un recurso")).tag("")
                    ForEach(workspace.availableResources.filter { $0.format == .legacyLSF }) { Text($0.title).tag($0.id) }
                }.disabled(loading)
                Button(L("Obtener texto"), action: loadPassage)
                    .disabled(loading || reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resourceID.isEmpty)
                if loading { ProgressView().controlSize(.small); Button(L("Cancelar")) { task?.cancel(); loading = false } }
            }
            Text(L("Texto del pasaje"))
            TextEditor(text: $passage).scrollContentBackground(.hidden).padding(8).frame(minHeight: 160).disabled(loading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            if original != nil { Text(L("Cambiar el pasaje, la referencia o la fuente reinicia el progreso.")).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Cancelar")) { dismiss() }; Button(L("Guardar"), action: save).disabled(loading) }
        }.padding(16).frame(width: 600, height: 520).modifier(MacPanelControlPresentation())
            .onAppear { if let original { reference = original.reference; passage = original.passage; source = original.source } }
            .onDisappear { task?.cancel() }
            .onChange(of: reference) { task?.cancel(); loading = false }
            .onChange(of: workspace.availableResources.map(\.id)) {
                if !workspace.availableResources.contains(where: { $0.id == resourceID }) { task?.cancel(); resourceID = ""; loading = false }
            }
    }
    private func loadPassage() {
        guard let resource = workspace.availableResources.first(where: { $0.id == resourceID }) else { return }
        let requested = reference
        task?.cancel(); loading = true; error = nil
        task = Task {
            do {
                let parsed = try BibleCopyPassage.parse(requested)
                let document = try await BibleCopyService().prepare(resource, passage: parsed,
                    abbreviation: resource.location.deletingPathExtension().lastPathComponent, includeFootnotes: false)
                let card = try ScriptureMemorySource.card(reference: requested, document: document)
                guard !Task.isCancelled, reference == requested, resourceID == resource.id,
                      workspace.availableResources.contains(where: { $0.id == resource.id && $0.location == resource.location && $0.legacyIdentifier == resource.legacyIdentifier }) else { return }
                passage = card.passage; source = card.source; loading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
        }
    }
    private func save() {
        var card = original ?? ScriptureMemoryCard(reference: reference, passage: passage)
        if let original, original.passage != passage || original.reference != reference.trimmingCharacters(in: .whitespacesAndNewlines) || original.source != source {
            card.attempts = 0; card.correct = 0; card.lastPracticed = nil
        }
        card.reference = reference.trimmingCharacters(in: .whitespacesAndNewlines); card.passage = passage; card.source = source
        do { try personal.saveScriptureMemoryCard(original: original, replacement: card); saved(card.id); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
private struct MemoryPractice: View {
    @Bindable var personal: WorkspacePersonalState
    let original: ScriptureMemoryCard
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var answer = ""
    @RebuildViewState private var result: Bool?
    @RebuildViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Practicar") { dismiss() }
            Text(original.reference).font(.headline)
            Text(L("Escribe el pasaje de memoria."))
            Text(L("Se ignoran mayúsculas y espacios; los acentos y la puntuación cuentan.")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $answer).scrollContentBackground(.hidden).padding(8).frame(minHeight: 150)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))).disabled(result != nil)
            if let result {
                Text(L(result ? "Respuesta correcta" : "Respuesta diferente")).font(.headline)
                ScrollView { Text(original.passage).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
            }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Cerrar")) { dismiss() }; Button(L("Comprobar respuesta"), action: check).disabled(result != nil || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(16).frame(width: 540, height: 500).modifier(MacPanelControlPresentation())
    }
    private func check() {
        do {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            let parts = calendar.dateComponents([.year, .month, .day], from: Date())
            guard let year = parts.year, let month = parts.month, let day = parts.day else { throw PersonalStateError.invalid("La respuesta o fecha del ejercicio no es válida.") }
            let date = try ReadingDay(year: year, month: month, day: day)
            var card = original; let matched = try card.record(answer: answer, on: date)
            try personal.saveScriptureMemoryCard(original: original, replacement: card); result = matched; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
