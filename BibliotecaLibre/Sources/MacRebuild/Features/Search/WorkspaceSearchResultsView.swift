import SwiftUI
import UniformTypeIdentifiers
import LibronixCore

struct WorkspaceSearchResultsView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var search: WorkspaceSearchController
    @Bindable var presentation: WorkspaceSearchResultsController
    @FocusState private var listFocused: Bool
    @RebuildViewState private var exportError: String?
    @RebuildViewState private var exportTask: Task<Void, Never>?
    @RebuildViewState private var exporting = false
    @RebuildViewState private var showsDistribution = false
    private func open(_ row: WorkspaceSearchResultRow) {
        guard search.canOpenResults else { return }
        presentation.selectedID = row.id
        workspace.openSearchResult(row.result, scope: search.scopeSnapshot, focus: row.focus)
    }
    private func openSelected() -> KeyPress.Result {
        guard search.canOpenResults, let row = presentation.selected else { return .ignored }
        open(row); return .handled
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if search.report != nil {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                    Text(L("Vista")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Vista"), value: presentation.layout.localizedTitle, selection: $presentation.layout) {
                        ForEach(WorkspaceSearchResultLayout.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                    }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                    Text(L("Agrupar")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Agrupar"), value: presentation.grouping.localizedTitle, selection: $presentation.grouping) {
                        ForEach(WorkspaceSearchResultGrouping.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                    }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                    Text(L("Orden")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Orden"), value: presentation.order.localizedTitle, selection: $presentation.order) {
                        ForEach(WorkspaceSearchResultOrder.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                    }
                    }
                }
                HStack {
                    Button { presentation.previous(); listFocused = true } label: {
                        Label(L("Resultado anterior"), systemImage: "chevron.up")
                    }.labelStyle(.iconOnly).help(L("Resultado anterior"))
                        .disabled(!presentation.canPrevious).keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button { presentation.next(); listFocused = true } label: {
                        Label(L("Resultado siguiente"), systemImage: "chevron.down")
                    }.labelStyle(.iconOnly).help(L("Resultado siguiente"))
                        .disabled(!presentation.canNext).keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    Text(LF("Resultado {current} de {total}", ["current": String((presentation.selectedIndex ?? -1) + 1), "total": String(presentation.rows.count)]))
                        .font(.caption).monospacedDigit()
                    Spacer()
                    Button(action: export) { Label(L("Exportar resultados…"), systemImage: "square.and.arrow.up").labelStyle(.iconOnly) }
                        .help(L("Exportar resultados…")).disabled(!search.canExportResults || exporting)
                    if search.report?.unit == .bibleVerse {
                        Button { showsDistribution = true } label: { Label(L("Distribución de resultados"), systemImage: "chart.bar.xaxis").labelStyle(.iconOnly) }
                            .help(L("Distribución de resultados"))
                            .disabled(search.report?.unit != .bibleVerse || search.isSearching || !search.canOpenResults)
                    }
                    Button(L("Abrir")) { _ = openSelected() }.disabled(presentation.selected == nil || !search.canOpenResults)
                }
                if exporting { ProgressView().controlSize(.small) }
                if let exportError { Text(exportError).foregroundStyle(.red).textSelection(.enabled) }
            }
            ScrollViewReader { proxy in
                List(selection: $presentation.selectedID) {
                    ForEach(presentation.sections) { section in
                        if let title = section.title {
                            Section { rows(section.rows) } header: { Text(verbatim: title) }
                        } else { rows(section.rows) }
                    }
                }
                .accessibilityLabel(L("Resultados de búsqueda"))
                .focused($listFocused)
                .onKeyPress(.return) { openSelected() }
                .onChange(of: presentation.selectedID) { if let id = presentation.selectedID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: presentation.revision) { if let id = presentation.selectedID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: presentation.layout) { if let id = presentation.selectedID { proxy.scrollTo(id, anchor: .center) } }
            }.frame(minHeight: 200, maxHeight: .infinity)
            if search.report?.contextCoverageComplete == false {
                Text(L("Algunos contextos no se muestran por el límite de presentación. Puedes abrir las coincidencias."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.onDisappear { exportTask?.cancel(); exportTask = nil; exporting = false }
            .sheet(isPresented: $showsDistribution) {
                WorkspaceSearchDistributionView(workspace: workspace, search: search).modifier(AppInterfaceLanguage())
            }
    }
    private func export() {
        exportError = nil
        do {
            let snapshot = try search.exportSnapshot(), panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "Libron-X-search.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            exporting = true
            exportTask = Task {
                let writer = Task.detached(priority: .userInitiated) { try snapshot.write(to: url) }
                do {
                    try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
                } catch {
                    if !(error is CancellationError) { exportError = L(error.localizedDescription) }
                }
                exporting = false; exportTask = nil
            }
        } catch { exportError = L(error.localizedDescription) }
    }
    @ViewBuilder private func rows(_ value: [WorkspaceSearchResultRow]) -> some View {
        ForEach(value) { row in
            WorkspaceSearchResultRowView(row: row, layout: presentation.layout, showsResource: presentation.grouping == .none)
                .tag(row.id).id(row.id)
                .contentShape(Rectangle()).onTapGesture(count: 2) { open(row) }
                .accessibilityAction(named: Text(L("Abrir"))) { open(row) }
        }
    }
}

private struct WorkspaceSearchResultRowView: View {
    let row: WorkspaceSearchResultRow
    let layout: WorkspaceSearchResultLayout
    let showsResource: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    if showsResource { Text(verbatim: row.result.resourceTitle).font(.headline) }
                    Text(row.result.bibleReference ?? LF("Artículo {number}", ["number": String(row.result.sectionOrdinal + 1)])).font(.caption)
                    if let field = row.field { Text(verbatim: field.localizedTitle).font(.caption) }
                    Spacer()
                }
                if let parts = row.parts {
                    if layout == .aligned { aligned(parts) }
                    else { Text(context(parts)).lineLimit(3) }
                } else if row.isSummary {
                    Text(verbatim: row.result.snippet.text).lineLimit(3).foregroundStyle(.secondary)
                    Text(L(row.result.hitCount > 0 ? "Coincidencias omitidas por el límite" : "Resultado sin coincidencias positivas")).font(.caption)
                } else { Text(L("Contexto no disponible")).foregroundStyle(.secondary) }
            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func context(_ parts: WorkspaceSearchContextParts) -> AttributedString {
        var before = AttributedString((parts.omittedBefore ? "…" : "") + parts.before)
        var match = AttributedString((parts.partialStart ? "…" : "") + parts.match + (parts.partialEnd ? "…" : ""))
        match.font = .body.bold()
        before += match
        before += AttributedString(parts.after + (parts.omittedAfter ? "…" : ""))
        return before
    }
    private func aligned(_ parts: WorkspaceSearchContextParts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: (parts.omittedBefore ? "…" : "") + parts.before)
                .lineLimit(2).truncationMode(.head).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: (parts.partialStart ? "…" : "") + parts.match + (parts.partialEnd ? "…" : ""))
                .fontWeight(.semibold).lineLimit(2).frame(width: 160, alignment: .center)
            Text(verbatim: parts.after + (parts.omittedAfter ? "…" : ""))
                .lineLimit(2).truncationMode(.tail).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor extension WorkspaceSearchResultLayout {
    var localizedTitle: String { L(self == .context ? "Contexto" : "Contexto alineado") }
}
@MainActor extension WorkspaceSearchResultGrouping {
    var localizedTitle: String { L(self == .none ? "Sin agrupar" : "Recurso") }
}
@MainActor extension WorkspaceSearchResultOrder {
    var localizedTitle: String {
        switch self {
        case .source: L("Orden de búsqueda")
        case .titleAscending: L("Título A–Z")
        case .titleDescending: L("Título Z–A")
        case .mostHits: L("Más coincidencias por artículo")
        }
    }
}
