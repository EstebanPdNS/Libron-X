import SwiftUI
import Charts
import LibronixCore

struct WorkspaceSearchDistributionView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var search: WorkspaceSearchController
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var grouping = BibleSearchDistributionGrouping.book
    @RebuildViewState private var occurrences = false
    @RebuildViewState private var resourceID = ""
    @RebuildViewState private var rangeText = ""
    @RebuildViewState private var distribution: BibleSearchDistribution?
    @RebuildViewState private var selectedID: BibleSearchDistributionGroup.ID?
    @RebuildViewState private var page = 0
    @RebuildViewState private var error: String?
    private let pageSize = 40
    private var resources: [LibraryResource] { search.scopeSnapshot?.resources ?? [] }
    private var groups: [BibleSearchDistributionGroup] { distribution?.groups.filter { $0.id.resourceID == resourceID } ?? [] }
    private var visibleGroups: [BibleSearchDistributionGroup] { Array(groups.dropFirst(page * pageSize).prefix(pageSize)) }
    private var selected: BibleSearchDistributionGroup? { groups.first { $0.id == selectedID } }
    private func value(_ group: BibleSearchDistributionGroup) -> Int { occurrences ? group.retainedOccurrences : group.results.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Distribución de resultados") { dismiss() }
            HStack {
                Picker(L("Edición"), selection: $resourceID) {
                    ForEach(resources) { Text($0.title + " · " + ($0.libron?.edition ?? $0.fileName)).tag($0.id) }
                }
                Picker(L("Agrupar"), selection: $grouping) {
                    Text(L("Libro")).tag(BibleSearchDistributionGrouping.book)
                    Text(L("Capítulo")).tag(BibleSearchDistributionGrouping.chapter)
                    Text(L("Rangos personalizados")).tag(BibleSearchDistributionGrouping.ranges)
                }
            }
            Toggle(L("Contar coincidencias conservadas"), isOn: $occurrences)
            if grouping == .ranges {
                Text(L("Un rango por línea; los rangos solapados se cuentan por separado.")).font(.caption)
                HStack(alignment: .top) {
                    TextEditor(text: $rangeText).font(.body).frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(L("Rangos personalizados"))
                    Button(L("Actualizar gráfico"), action: rebuild)
                }
            }
            Text(L("Se cuentan los resultados conservados de cada edición. Las cuentas parciales no representan toda la biblioteca."))
                .font(.caption).foregroundStyle(.secondary)
            if distribution?.complete == false {
                Text(L("Distribución parcial: la búsqueda no cubrió todo el ámbito.")).font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    if !visibleGroups.isEmpty {
                        Chart(visibleGroups) { group in
                            BarMark(x: .value(L("Cuenta"), value(group)), y: .value(L("Grupo"), group.title))
                                .foregroundStyle(group.id == selectedID ? Color.accentColor : Color.accentColor.opacity(0.55))
                                .accessibilityLabel(group.title)
                                .accessibilityValue(String(value(group)))
                        }
                        .chartYScale(domain: visibleGroups.map(\.title))
                        .frame(height: CGFloat(max(140, visibleGroups.count * 28)))
                        .padding(.horizontal, 8)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleGroups) { group in
                            Button {
                                selectedID = group.id
                            } label: {
                                HStack {
                                    Text(group.title); Spacer(); Text(String(value(group))).monospacedDigit()
                                }.frame(maxWidth: .infinity)
                            }.accessibilityLabel(group.title + ": " + String(value(group)))
                        }
                    }
                }.frame(minWidth: 240, idealWidth: 320)
                VStack(alignment: .leading, spacing: 8) {
                    if let selected {
                        Text(selected.title).font(.headline)
                        Text(LF("Resultados: {results} · Coincidencias conservadas: {retained}/{observed}", [
                            "results": String(selected.results.count), "retained": String(selected.retainedOccurrences),
                            "observed": String(selected.observedOccurrences)])).font(.caption)
                        List(selected.results) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(result.bibleReference ?? result.articleTitle).font(.headline)
                                    Spacer(); Button(L("Abrir")) { open(result) }.disabled(!search.canOpenResults)
                                }
                                Text(verbatim: result.snippet.text).lineLimit(3).textSelection(.enabled)
                            }
                        }
                    } else { Text(L("Selecciona un grupo para ver sus resultados.")).foregroundStyle(.secondary) }
                }.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            HStack {
                Button(L("Página anterior")) { page -= 1 }.disabled(page == 0)
                Text(LF("Grupos: {count}", ["count": String(groups.count)])).font(.caption)
                Button(L("Página siguiente")) { page += 1 }.disabled((page + 1) * pageSize >= groups.count)
                Spacer()
            }
        }.padding(16).frame(minWidth: 680, idealWidth: 860, minHeight: 540, idealHeight: 740)
            .modifier(MacPanelControlPresentation())
            .onAppear { resourceID = resources.first?.id ?? ""; rebuild() }
            .onChange(of: grouping) { rebuild() }
            .onChange(of: resourceID) { page = 0; selectedID = groups.first?.id }
            .onChange(of: search.configurationChanged) { if search.configurationChanged { dismiss() } }
            .onChange(of: search.report?.unit) { if search.report == nil { dismiss() } }
    }
    private func rebuild() {
        distribution = nil; selectedID = nil; page = 0; error = nil
        guard let report = search.report else { return }
        do {
            distribution = try .build(report: report, resources: resources, grouping: grouping,
                ranges: rangeText.components(separatedBy: .newlines), scopeComplete: search.coverageComplete)
            selectedID = groups.first?.id
        } catch { self.error = L(error.localizedDescription) }
    }
    private func open(_ result: LibrarySearchResult) {
        guard search.canOpenResults else { return }
        workspace.openSearchResult(result, scope: search.scopeSnapshot)
        if workspace.activeTool == nil { dismiss() }
        else { error = search.error }
    }
}
