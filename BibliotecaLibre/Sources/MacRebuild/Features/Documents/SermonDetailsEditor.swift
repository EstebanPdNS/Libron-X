import AppKit
import SwiftUI
import LibronixCore

struct SermonDetailsDraft: Equatable {
    var title = ""
    var speaker = ""
    var series = ""
    var venue = ""
    var tags = ""
    var passages = ""
    var hasDate = false
    var date = Date()
    init(document: StudyDocument?) {
        guard let document else { return }
        title = document.title
        let metadata = document.sermon!
        speaker = metadata.speaker; series = metadata.series; venue = metadata.venue
        tags = metadata.tags.joined(separator: ", "); passages = metadata.passages.joined(separator: "\n")
        if let day = metadata.preachedOn {
            hasDate = true
            date = Calendar(identifier: .gregorian).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        }
    }
    func metadata() throws -> SermonMetadata {
        var result = SermonMetadata()
        result.speaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        result.series = series.trimmingCharacters(in: .whitespacesAndNewlines)
        result.venue = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        result.passages = passages.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if hasDate {
            let day = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
            result.preachedOn = try ReadingDay(year: day.year!, month: day.month!, day: day.day!)
        }
        return result
    }
}

struct SermonDetailsEditor: View {
    let workspace: StudyWorkspace
    let original: StudyDocument?
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var draft: SermonDetailsDraft
    @RebuildViewState private var initial: SermonDetailsDraft
    @RebuildViewState private var error: String?
    @RebuildViewState private var discarding = false
    init(workspace: StudyWorkspace, original: StudyDocument?, saved: @escaping (UUID) -> Void) {
        self.workspace = workspace; self.original = original; self.saved = saved
        let value = SermonDetailsDraft(document: original)
        _draft = RebuildViewState(wrappedValue: value); _initial = RebuildViewState(wrappedValue: value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: original == nil ? "Nuevo sermón" : "Detalles del sermón", close: close)
            TextField(L("Título"), text: $draft.title).macInputStyle()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Predicador")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("Predicador"), text: $draft.speaker).macInputStyle()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Serie")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("Serie"), text: $draft.series).macInputStyle()
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Lugar")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("Lugar"), text: $draft.venue).macInputStyle()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Etiquetas")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("Etiquetas separadas por comas"), text: $draft.tags).macInputStyle()
                }
            }
            HStack(spacing: 12) {
                Toggle(L("Fecha"), isOn: $draft.hasDate)
                DatePicker(L("Fecha"), selection: $draft.date, displayedComponents: .date)
                    .labelsHidden().disabled(!draft.hasDate).environment(\.calendar, Calendar(identifier: .gregorian))
                Spacer()
            }
            Text(L("Pasajes bíblicos")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.passages).scrollContentBackground(.hidden).padding(8)
                .frame(height: 80).macEditorSurface().accessibilityLabel(L("Pasajes bíblicos"))
            Text(L("Un pasaje por línea. Las referencias se conservan tal como se escriben."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L(error)).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button(L("Cancelar"), action: close).keyboardShortcut(.cancelAction)
                Button(L("Guardar"), action: save).keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).frame(width: 620).modifier(MacPanelControlPresentation())
            .interactiveDismissDisabled()
            .onChange(of: draft) { error = nil }
            .onAppear {
                workspace.sermonDraftCloseGuard = {
                    guard draft != initial else { return true }
                    let alert = NSAlert(); alert.messageText = L("Descartar cambios")
                    alert.informativeText = L("Se perderán los cambios del sermón que no hayas guardado.")
                    alert.addButton(withTitle: L("Cancelar")); alert.addButton(withTitle: L("Descartar"))
                    return alert.runModal() == .alertSecondButtonReturn
                }
            }
            .onDisappear { workspace.sermonDraftCloseGuard = nil }
            .alert(L("Descartar cambios"), isPresented: $discarding) {
                Button(L("Cancelar"), role: .cancel) { }
                Button(L("Descartar"), role: .destructive) { dismiss() }
            } message: { Text(L("Se perderán los cambios del sermón que no hayas guardado.")) }
    }
    private func close() { if draft == initial { dismiss() } else { discarding = true } }
    private func save() {
        do {
            let id = try workspace.personal.saveSermonDetails(original: original,
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), metadata: draft.metadata())
            saved(id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
