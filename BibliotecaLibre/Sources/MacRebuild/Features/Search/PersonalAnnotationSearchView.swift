import AppKit
import SwiftUI
import LibronixCore

struct PersonalAnnotationSearchView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var search: PersonalAnnotationSearchController
    private func highlighted(_ result: PersonalAnnotationResult) -> AttributedString {
        let text = NSMutableAttributedString(string: result.snippet)
        if Range(result.snippetMatch.nsRange, in: result.snippet) != nil {
            text.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: result.snippetMatch.nsRange)
        }
        return AttributedString(text)
    }
    private func localizedWarning(_ warning: String) -> String {
        let pairs = [
            ("Recurso no disponible", "Recurso no disponible"),
            ("Sección no disponible", "Sección no disponible"),
            ("Resaltado no verificable", "Resaltado no verificable"),
            ("Se alcanzó el límite de búsqueda", "Se alcanzó el límite de búsqueda"),
            ("Algunas notas antiguas no tienen un recurso verificado.", "Algunas notas antiguas no tienen un recurso verificado."),
            ("no se pudo abrir el RTF guardado; se busca la vista de solo lectura del original.", "No se pudo abrir el RTF guardado; se analiza la vista de solo lectura del original."),
            ("el HTML original conserva objetos no compatibles; se busca el texto visible.", "El HTML original conserva objetos no compatibles; se analiza el texto visible.")
        ]
        for (raw, key) in pairs where warning.contains(raw) { return warning.replacingOccurrences(of: raw, with: L(key)) }
        return warning
    }
    private func run() {
        search.run(documents: workspace.personal.documents, highlights: workspace.personal.highlights, resources: workspace.availableResources)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("Texto en notas o resaltados"), text: $search.query).macInputStyle().onSubmit(run)
                if search.isSearching { Button(L("Cancelar"), action: search.clear) }
                else { Button(L("Buscar"), action: run).disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!search.filter.includeNotes && !search.filter.includeHighlights)) }
            }
            HStack {
                Toggle(L("Notas"), isOn: $search.filter.includeNotes)
                Toggle(L("Resaltados"), isOn: $search.filter.includeHighlights)
                Spacer()
            }
            HStack {
                Picker(L("Cuaderno"), selection: $search.filter.documentID) {
                    Text(L("Todos los cuadernos")).tag(Optional<UUID>.none)
                    ForEach(workspace.personal.documents.filter { $0.kind == .notebook }) { Text($0.title).tag(Optional($0.id)) }
                }
                Picker(L("Color"), selection: $search.filter.color) {
                    Text(L("Todos los colores")).tag(Optional<String>.none)
                    Text(L("Amarillo")).tag(Optional("yellow"))
                    Text(L("Verde")).tag(Optional("green"))
                    Text(L("Azul")).tag(Optional("blue"))
                    Text(L("Rosa")).tag(Optional("pink"))
                }
            }
            Picker(L("Recurso"), selection: $search.filter.resourceID) {
                Text(L("Todos los recursos")).tag(Optional<String>.none)
                ForEach(workspace.availableResources) { Text($0.title).tag(Optional($0.id)) }
            }
            Text(L("El filtro de cuaderno incluye notas; el de color incluye resaltados. El texto se busca sin distinguir mayúsculas ni acentos."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = search.error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if search.isSearching { ProgressView().controlSize(.small) }
            if let report = search.report {
                List(report.results) { result in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.headline)
                            Text(highlighted(result)).lineLimit(3).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        Button(L("Abrir")) { workspace.openPersonalAnnotationResult(result) }
                    }.contentShape(Rectangle()).onTapGesture(count: 2) { workspace.openPersonalAnnotationResult(result) }
                }.frame(minHeight: 180)
                Text(LF("{count} resultados", ["count": String(report.results.count)])).font(.caption)
                if !report.complete {
                    DisclosureGroup(L("La búsqueda tiene resultados parciales o fuentes pendientes")) {
                        ScrollView { Text(report.warnings.isEmpty ? L("Se alcanzó el límite de búsqueda") : report.warnings.map(localizedWarning).joined(separator: "\n"))
                                .font(.caption).textSelection(.enabled) }.frame(maxHeight: 100)
                    }
                } else if report.results.isEmpty { Text(L("No se encontraron coincidencias.")).foregroundStyle(.secondary) }
            }
        }.padding(16)
            .onChange(of: search.query) { search.clear() }
            .onChange(of: search.filter) { search.clear() }
            .onChange(of: workspace.personal.documents) { search.clear() }
            .onChange(of: workspace.personal.highlights) { search.clear() }
            .onChange(of: workspace.availableResources) { search.clear() }
            .onDisappear { search.clear() }
    }
}
