import SwiftUI
import LibronixCore

struct WorkspaceReferenceSearchView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var search: WorkspaceReferenceSearchController
    private func run() { search.run(resources: workspace.availableResources, documents: workspace.personal.documents) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("Referencia, por ejemplo Jn 3:16 o Jn 3:16(RVR60)"), text: $search.query)
                    .macInputStyle().onSubmit(run)
                if search.isSearching { Button(L("Cancelar"), action: search.cancel) }
                else { Button(L("Buscar"), action: run).disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(L("Recursos de la biblioteca"), isOn: $search.includeLibrary)
                    Toggle(L("Documentos personales"), isOn: $search.includeDocuments)
                }
                HStack {
                    Toggle(L("Toda la biblioteca"), isOn: $search.allResources)
                    Picker(L("Recurso"), selection: Binding(get: { search.resourceID ?? "" }, set: { search.resourceID = $0 })) {
                        Text(L("Selecciona un recurso")).tag("")
                        ForEach(workspace.availableResources) { Text($0.title).tag($0.id) }
                    }.disabled(search.allResources)
                }.disabled(!search.includeLibrary)
            }.disabled(search.isSearching)
            Text(L("Encuentra menciones explícitas de pasajes. Una edición entre paréntesis limita la búsqueda a citas que indican esa edición."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = search.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if search.isSearching {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progressText)
                }.font(.caption)
            }
            List(search.report?.results ?? []) { result in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(result.sourceTitle).font(.headline)
                        HStack {
                            Text(result.mention.label)
                            if let edition = result.mention.citation.edition { Text(edition.uppercased()).foregroundStyle(.secondary) }
                            if result.personalDestination != nil { Image(systemName: "doc.text").accessibilityLabel(L("Documento personal")) }
                        }.font(.caption)
                        Text(result.snippet.text).lineLimit(3).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    Button(L("Abrir")) { workspace.openReferenceSearchResult(result) }
                }.contentShape(Rectangle()).onTapGesture(count: 2) { workspace.openReferenceSearchResult(result) }
            }
            if let report = search.report {
                Text(LF("{results} resultados · {articles} artículos · {fields} campos personales", ["results": String(report.results.count), "articles": String(report.counters.articlesExamined), "fields": String(report.personalFieldsExamined)])).font(.caption)
                if !report.coverageComplete {
                    DisclosureGroup(L("La búsqueda tiene resultados parciales o fuentes pendientes")) {
                        ScrollView { Text(details(report)).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                    }
                } else if report.results.isEmpty { Text(L("No se encontraron referencias coincidentes.")).foregroundStyle(.secondary) }
            }
        }.padding(16)
    }
    private var progressText: String {
        LF("{articles} artículos · {fields} campos personales", ["articles": String(search.progress?.counters.articlesExamined ?? 0), "fields": String(search.progress?.personalFieldsExamined ?? 0)])
    }
    private func details(_ report: BibleReferenceSearchReport) -> String {
        var lines = report.limitReason.map { [L("Se alcanzó el límite de búsqueda") + ": " + $0.rawValue] } ?? []
        lines += report.resources.filter { $0.status != .complete }.map { $0.resourceTitle + ": " + ($0.warnings + $0.errors.map(\.message)).joined(separator: " ") }
        lines += report.documents.filter { !$0.complete }.map { $0.title + ": " + ($0.warnings + $0.errors).joined(separator: " ") }
        return lines.joined(separator: "\n")
    }
}
