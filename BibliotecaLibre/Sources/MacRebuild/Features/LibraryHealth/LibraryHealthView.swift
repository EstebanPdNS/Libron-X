import SwiftUI

struct LibraryHealthView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var report: LibraryHealthReport?
    @RebuildViewState private var isLoading = false
    @RebuildViewState private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let report { Text(LF("{count} recursos revisados", ["count": String(report.resourceCount)])) }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button(L("Actualizar")) { refresh() }.disabled(isLoading)
            }
            Text(L("Comprueba archivos, avisos y anotaciones; no verifica todas las conversiones ni los índices."))
                .font(.caption).foregroundStyle(.secondary)
            if let report {
                if report.issues.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.largeTitle)
                        Text(L("No se encontraron problemas en estas comprobaciones."))
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                List(report.issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L(title(issue.kind)), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(issue.title).font(.headline).textSelection(.enabled)
                        if !issue.detail.isEmpty { Text(issue.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(.vertical, 4)
                }.frame(minHeight: 240, idealHeight: 340, maxHeight: 400)
                }
                if report.omittedIssueCount > 0 {
                    Text(LF("Se omitieron {count} problemas adicionales.", ["count": String(report.omittedIssueCount)]))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28) }
        }.padding(16).onAppear(perform: refresh).onDisappear { task?.cancel() }
    }
    private func title(_ kind: LibraryHealthIssue.Kind) -> String {
        switch kind {
        case .missingResource: "Archivo ausente"
        case .invalidResource: "Recurso inválido"
        case .opaqueResource: "Recurso no descodificado"
        case .resourceWarning: "Aviso del recurso"
        case .missingAnnotationSource: "Origen de anotación ausente"
        case .unresolvedAnnotation: "Anotación sin resolver"
        case .conversionIssue: "Estado de conversión"
        case .unresolvedLink: "Destino"
        case .damagedIndex: "Índice de búsqueda dañado"
        case .indexUnavailable: "Índice de búsqueda sin verificar"
        }
    }
    private func refresh() {
        task?.cancel(); isLoading = true
        let resources = workspace.resources, documents = workspace.personal.documents, highlights = workspace.personal.highlights
        let favorites = workspace.personal.favorites.items, bookmarks = workspace.personal.bookmarks.slots
        task = Task {
            let worker = Task.detached { LibraryHealthReport.inspect(resources: resources, documents: documents, highlights: highlights, favorites: favorites, bookmarks: bookmarks) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            report = result; isLoading = false
        }
    }
}
