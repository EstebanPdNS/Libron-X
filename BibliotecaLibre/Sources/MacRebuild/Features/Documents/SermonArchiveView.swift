import SwiftUI
import LibronixCore

private struct SermonEditRequest: Identifiable { let id = UUID(); let original: StudyDocument? }
struct SermonArchiveView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var query = ""
    @RebuildViewState private var order = SermonArchiveOrder.newest
    @RebuildViewState private var report = SermonArchiveSearchReport()
    @RebuildViewState private var selectedID: UUID?
    @RebuildViewState private var editing: SermonEditRequest?
    @RebuildViewState private var deleting: StudyDocument?
    @RebuildViewState private var error: String?
    @RebuildViewState private var loading = false
    @RebuildViewState private var task: Task<Void, Never>?
    private var selected: StudyDocument? { report.documents.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("Buscar sermones"), text: $query).macInputStyle()
            HStack(spacing: 12) {
                MacSelectionMenu(L("Orden"), value: order.localizedTitle, selection: $order) {
                    ForEach(SermonArchiveOrder.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { editing = .init(original: nil) } label: { Label(L("Nuevo sermón"), systemImage: "plus") }
            }
            if workspace.personal.documents.contains(where: { $0.kind == .sermon }) {
                List(report.documents, selection: $selectedID) { document in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(document.title, systemImage: "text.bubble").font(.headline)
                        let metadata = document.sermon!
                        Text([metadata.dateText, metadata.speaker, metadata.series].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if !metadata.passages.isEmpty { Text(metadata.passages.joined(separator: " · ")).font(.caption).lineLimit(2) }
                    }.padding(.vertical, 4).tag(document.id).contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(document) }
                }.frame(height: min(360, max(180, CGFloat(report.documents.count) * 72)))
                    .overlay {
                        if report.documents.isEmpty && !loading { Text(L("No se encontraron coincidencias.")).foregroundStyle(.secondary).allowsHitTesting(false) }
                    }
                HStack(spacing: 12) {
                    Button { if let selected { editing = .init(original: selected) } } label: { Label(L("Detalles del sermón"), systemImage: "slider.horizontal.3") }.disabled(selected == nil)
                    Button { deleting = selected } label: { Label(L("Eliminar"), systemImage: "trash").labelStyle(.iconOnly) }.help(L("Eliminar sermón")).disabled(selected == nil)
                    Spacer()
                    Text(LF("{count} sermones", ["count": String(report.documents.count)])).font(.caption).foregroundStyle(.secondary)
                    Button(L("Abrir")) { if let selected { open(selected) } }.disabled(selected == nil)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(L("No hay sermones guardados.")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            if report.incompleteDocuments > 0 {
                Text(L("Algunas partes del documento no se pudieron analizar por completo.")).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(L(error)).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }.padding(16).onAppear(perform: refresh)
            .onChange(of: query) { refresh() }.onChange(of: order) { refresh() }
            .onChange(of: workspace.personal.documents) { refresh() }
            .onDisappear { task?.cancel() }
            .sheet(item: $editing) { request in
                SermonDetailsEditor(workspace: workspace, original: request.original) { selectedID = $0 }.modifier(AppInterfaceLanguage())
            }
            .alert(L("Eliminar sermón"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L("Cancelar"), role: .cancel) { deleting = nil }
                Button(L("Eliminar"), role: .destructive) {
                    guard let deleting else { return }
                    do { try workspace.personal.deleteSermon(deleting); selectedID = nil; self.deleting = nil }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text(L("El sermón se quitará del archivo. Sus versiones guardadas seguirán disponibles en el historial.")) }
    }
    private func open(_ document: StudyDocument) {
        workspace.personal.selectedDocumentID = document.id; workspace.activeTool = .documents
    }
    private func refresh() {
        task?.cancel(); loading = true
        let documents = workspace.personal.documents, text = query, order = order
        task = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let worker = Task.detached { Result { try SermonArchiveSearch.search(text, documents: documents, order: order) } }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): report = value; error = nil
            case .failure(let failure): report = .init(); error = failure.localizedDescription
            }
            loading = false; task = nil
        }
    }
}
@MainActor extension SermonArchiveOrder {
    var localizedTitle: String {
        switch self {
        case .newest: L("Fecha más reciente")
        case .oldest: L("Fecha más antigua")
        case .title: L("Título A–Z")
        case .speaker: L("Predicador")
        }
    }
}
