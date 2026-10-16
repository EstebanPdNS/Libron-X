import AppKit
import LibronixCore
import SwiftUI

struct LibrarySearchWorkspace: View {
    @Bindable var model: LibrarySearchModel
    let resources: [LibraryResource]
    let selectedResource: LibraryResource?
    let openResult: (LibrarySearchResult) -> Void
    @FocusState private var queryIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Buscar en libros").font(.system(size: 28, weight: .medium, design: .serif))
                HStack {
                    TextField("Palabra, frase o consulta", text: $model.queryText)
                        .textFieldStyle(.roundedBorder).focused($queryIsFocused)
                        .onSubmit { start() }
                    if model.isSearching { Button("Cancelar", action: model.cancel) }
                    else { Button("Buscar", action: start).disabled(model.queryText.isEmpty) }
                }
                Picker("Buscar en", selection: $model.searchAllResources) {
                    Text(selectedResource?.title ?? "Selecciona un recurso").tag(false)
                    Text("Toda la biblioteca").tag(true)
                }.disabled(model.isSearching)
                Picker("Resultados por", selection: $model.unit) {
                    Text("Artículo").tag(LibrarySearchUnit.article)
                    Text("Versículo bíblico").tag(LibrarySearchUnit.bibleVerse)
                }.disabled(model.isSearching)
                HStack(spacing: 14) {
                    Toggle("Mayúsculas", isOn: $model.caseSensitive)
                    Toggle("Acentos", isOn: $model.diacriticSensitive)
                    Toggle("Palabras completas", isOn: $model.wholeWords)
                }.toggleStyle(.checkbox).font(.caption).disabled(model.isSearching)
                Text("Usa comillas para frases, AND, OR, NOT y paréntesis. La consulta se aplica dentro de cada \(model.unit == .article ? "artículo" : "versículo con referencia compatible").")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(24)
            Divider()
            if let progress = model.progress {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.currentResourceTitle ?? "Leyendo recursos…").font(.caption).lineLimit(1)
                        Text("\(progress.counters.articlesExamined) artículos examinados · \(progress.counters.matchingArticles) con coincidencias")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
            if let report = model.report {
                reportSummary(report)
                if report.results.isEmpty {
                    ContentUnavailableView(report.coverageComplete ? "Sin coincidencias" : "Sin coincidencias en el contenido examinado",
                        systemImage: "magnifyingglass", description: Text(report.coverageComplete
                            ? "Prueba otra consulta u opciones." : "El ámbito incluye contenido incompatible o llegó a un límite de búsqueda."))
                } else {
                    List(report.results) { result in
                        Button { openResult(result) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(result.articleTitle).font(.headline).lineLimit(2)
                                    Spacer()
                                    Text("\(result.hitCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text(result.resourceTitle).font(.caption).foregroundStyle(.secondary)
                                Text(attributedSnippet(result.snippet)).font(.system(size: 13)).lineLimit(4)
                            }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }.listStyle(.inset)
                }
                DisclosureGroup("Cobertura por recurso") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.resourceReports) { resource in
                                Text("\(resource.resourceTitle): \(resource.articlesDecoded) artículos leídos, \(resource.articlesFailed) incompatibles")
                                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 140)
                }.font(.caption).padding(20)
            } else if !model.isSearching {
                ContentUnavailableView("Encuentra texto en tu biblioteca", systemImage: "text.magnifyingglass",
                    description: Text("Elige un recurso y escribe una consulta. Los resultados abren el artículo original y seleccionan la coincidencia."))
            } else { Spacer() }
            Divider()
            Text("Búsqueda de texto en contenido compatible. Índices originales, proximidad, lemas y Strong continúan en desarrollo.")
                .font(.caption2).foregroundStyle(.secondary).padding(18)
        }.background(LibraryPalette.paper)
        .onChange(of: model.focusRequest) { _, _ in queryIsFocused = true }
    }
    private func start() { model.run(resources: resources, selectedResource: selectedResource) }
    private func reportSummary(_ report: LibrarySearchReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(report.unit == .article ? report.counters.matchingArticles : report.counters.matchingVerses) \(report.unit == .article ? "artículos" : "versículos") con coincidencias · \(report.counters.occurrencesObserved) ocurrencias")
                .font(.callout.weight(.medium))
            Text("\(report.counters.articlesDecoded) de \(report.counters.articlesTotalKnown) artículos leídos · \(report.elapsedSeconds, specifier: "%.1f") s")
                .font(.caption).foregroundStyle(.secondary)
            if report.unit == .bibleVerse {
                Text("\(report.counters.versesExamined) versículos examinados. Los intervalos entre artículos y otras clases de referencias siguen pendientes de verificación.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !report.coverageComplete {
                Label(report.truncated ? "Resultado parcial: se alcanzó un límite de búsqueda." : "Resultado parcial: hay contenido incompatible en el ámbito.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
    }
    private func attributedSnippet(_ snippet: LibrarySearchSnippet) -> AttributedString {
        let string = NSMutableAttributedString(string: snippet.text)
        for range in snippet.highlightRanges where range.location >= 0 && range.length >= 0 && range.upperBound <= string.length {
            string.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), range: range.nsRange)
        }
        return AttributedString(string)
    }
}
