import AppKit
import SwiftUI
import LibronixCore

struct ReferenceExtractionRequest: Identifiable { let id: UUID }

struct StudyReferenceExtractionView: View {
    let personal: WorkspacePersonalState
    let destinationID: UUID
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var sourceID: UUID?
    @RebuildViewState private var text = ""
    @RebuildViewState private var report: StudyReferenceExtraction?
    @RebuildViewState private var selected: Set<UUID> = []
    @RebuildViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Extraer referencias") { dismiss() }
            Picker(L("Origen"), selection: $sourceID) {
                Text(L("Texto")).tag(Optional<UUID>.none)
                ForEach(personal.documents.filter { $0.id != destinationID }) { document in
                    Text(document.title).tag(Optional(document.id))
                }
            }
            if sourceID == nil {
                Text(L("Pega o escribe el texto que quieres analizar.")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.body).frame(minHeight: 80, idealHeight: 100, maxHeight: 120)
                    .accessibilityLabel(L("Texto"))
                HStack {
                    Button(L("Pegar del portapapeles")) { paste() }
                    Spacer()
                    Button(L("Extraer"), action: extract).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack { Spacer(); Button(L("Extraer"), action: extract) }
            }
            Text(L("Solo se incluyen referencias reconocidas; revisa el resultado antes de agregarlo."))
                .font(.caption).foregroundStyle(.secondary)
            if let report {
                if !report.complete {
                    Text(L("Algunas partes del documento no se pudieron analizar por completo."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.warnings, id: \.self) { Text(localizedWarning($0)).font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Text(LF("{count} referencias", ["count": String(report.items.count)])).font(.headline)
                    Spacer()
                    Button(L("Seleccionar todo")) { selected = Set(report.items.map(\.id)) }.disabled(report.items.isEmpty)
                }
                if report.items.isEmpty { Text(L("No se encontraron referencias reconocidas.")).foregroundStyle(.secondary) }
                else {
                    List(report.items) { item in
                        Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                            if value { selected.insert(item.id) } else { selected.remove(item.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.mention.label)
                                if item.reference != item.mention.label {
                                    Text(item.reference).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.frame(minHeight: 120, maxHeight: .infinity)
                }
            }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("Cancelar")) { dismiss() }
                Button(L("Agregar"), action: add).disabled(selected.isEmpty || report == nil)
            }
        }.padding(20).frame(minWidth: 560, idealWidth: 620,
                            minHeight: report == nil ? nil : 440, idealHeight: report == nil ? nil : 580)
            .modifier(MacPanelControlPresentation()).modifier(AppInterfaceLanguage())
            .onChange(of: sourceID) { report = nil; selected = []; error = nil }
            .onChange(of: text) { report = nil; selected = []; error = nil }
    }
    private func paste() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            error = L("No hay texto en el portapapeles."); return
        }
        if !text.isEmpty { text += "\n" }
        text += value
    }
    private func localizedWarning(_ warning: String) -> String {
        let translations = [
            (": no se pudo abrir el RTF guardado; se busca la vista de solo lectura del original.",
             "No se pudo abrir el RTF guardado; se analiza la vista de solo lectura del original."),
            (": el HTML original conserva objetos no compatibles; se busca el texto visible.",
             "El HTML original conserva objetos no compatibles; se analiza el texto visible.")
        ]
        for (suffix, key) in translations where warning.hasSuffix(suffix) {
            return String(warning.dropLast(suffix.count)) + ": " + L(key)
        }
        return warning
    }
    private func extract() {
        do {
            let result: StudyReferenceExtraction
            if let sourceID {
                guard let document = personal.documents.first(where: { $0.id == sourceID }) else {
                    throw PersonalStateError.invalid("Selecciona un documento")
                }
                result = try .document(document)
            } else { result = try .text(text, title: L("Texto")) }
            report = result; selected = Set(result.items.map(\.id)); error = nil
        } catch { self.error = error.localizedDescription; report = nil; selected = [] }
    }
    private func add() {
        guard let report else { return }
        do {
            try report.validate(against: personal.documents)
            try personal.appendExtractedReferences(report.items.filter { selected.contains($0.id) }.map(\.reference), to: destinationID)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
