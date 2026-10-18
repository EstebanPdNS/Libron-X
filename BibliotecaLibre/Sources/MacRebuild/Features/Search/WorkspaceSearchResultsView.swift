import SwiftUI
import LibronixCore

struct WorkspaceSearchResultsView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var search: WorkspaceSearchController
    @Bindable var presentation: WorkspaceSearchResultsController
    @FocusState private var listFocused: Bool
    private func open(_ row: WorkspaceSearchResultRow) {
        presentation.selectedID = row.id
        workspace.openSearchResult(row.result, scope: search.scopeSnapshot, focus: row.focus)
    }
    private func openSelected() -> KeyPress.Result {
        guard let row = presentation.selected else { return .ignored }
        open(row); return .handled
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if search.report != nil {
                HStack {
                    Picker(L("Vista"), selection: $presentation.layout) {
                        Text(L("Contexto")).tag(WorkspaceSearchResultLayout.context)
                        Text(L("Contexto alineado")).tag(WorkspaceSearchResultLayout.aligned)
                    }
                    Picker(L("Agrupar"), selection: $presentation.grouping) {
                        Text(L("Sin agrupar")).tag(WorkspaceSearchResultGrouping.none)
                        Text(L("Recurso")).tag(WorkspaceSearchResultGrouping.resource)
                    }
                    Picker(L("Orden"), selection: $presentation.order) {
                        Text(L("Orden de búsqueda")).tag(WorkspaceSearchResultOrder.source)
                        Text(L("Título A–Z")).tag(WorkspaceSearchResultOrder.titleAscending)
                        Text(L("Título Z–A")).tag(WorkspaceSearchResultOrder.titleDescending)
                        Text(L("Más coincidencias por artículo")).tag(WorkspaceSearchResultOrder.mostHits)
                    }
                }
                HStack {
                    Button { presentation.previous(); listFocused = true } label: {
                        Label(L("Resultado anterior"), systemImage: "chevron.up")
                    }.disabled(!presentation.canPrevious).keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button { presentation.next(); listFocused = true } label: {
                        Label(L("Resultado siguiente"), systemImage: "chevron.down")
                    }.disabled(!presentation.canNext).keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    Text(LF("Resultado {current} de {total}", ["current": String((presentation.selectedIndex ?? -1) + 1), "total": String(presentation.rows.count)]))
                        .font(.caption).monospacedDigit()
                    Spacer()
                    Button(L("Abrir selección")) { _ = openSelected() }.disabled(presentation.selected == nil)
                }
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
            }.frame(minHeight: 150)
            if search.report?.contextCoverageComplete == false {
                Text(L("Algunos contextos no se muestran por el límite de presentación. Puedes abrir las coincidencias."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private func rows(_ value: [WorkspaceSearchResultRow]) -> some View {
        ForEach(value) { row in
            WorkspaceSearchResultRowView(row: row, layout: presentation.layout, showsResource: presentation.grouping == .none) { open(row) }
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
    let open: () -> Void
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
            Button(L("Abrir"), action: open)
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
