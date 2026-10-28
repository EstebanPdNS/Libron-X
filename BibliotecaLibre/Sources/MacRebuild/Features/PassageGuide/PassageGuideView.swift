import SwiftUI
import LibronixCore

struct PassageGuideView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var controller: PassageGuideController
    @RebuildViewState private var openingError: String?
    private var commentaries: [PassageGuideMatch] { controller.matches.filter { $0.kind == .commentary } }
    private var dictionaries: [PassageGuideMatch] { controller.matches.filter { $0.kind == .dictionary || $0.kind == .lexicon } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("Referencia bíblica"), text: $controller.passage).macInputStyle()
                    .onSubmit { controller.run(workspace: workspace) }
                Button(L("Generar guía")) { controller.run(workspace: workspace) }
                    .disabled(controller.passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isLoading)
                if controller.isLoading { Button(L("Cancelar")) { controller.clear() } }
            }
            TextField(L("Palabras para diccionarios, separadas por comas (opcional)"), text: $controller.terms).macInputStyle()
            Picker(L("Buscar referencias en"), selection: $controller.referenceResourceID) {
                Text(L("Toda la biblioteca")).tag(Optional<String>.none)
                ForEach(workspace.availableResources.filter { !$0.isHelp }) { resource in
                    Text(resource.title + " · " + resource.fileName).tag(Optional(resource.id))
                }
            }
            Text(L("Las referencias se buscan en los recursos disponibles; no se convierten versificaciones."))
                .font(.caption).foregroundStyle(.secondary)
            if controller.isLoading {
                HStack { ProgressView().controlSize(.small); Text(controller.currentSource ?? L("Buscando referencias…")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let error = controller.error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let openingError { Text(L(openingError)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if controller.completed || !controller.matches.isEmpty || controller.references != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        sectionTitle("Comentarios", count: commentaries.count)
                        if controller.commentaryCount == 0 { Text(L("No hay comentarios disponibles.")).foregroundStyle(.secondary) }
                        else if controller.completed && commentaries.isEmpty { Text(L("No se encontraron coincidencias verificadas.")).foregroundStyle(.secondary) }
                        ForEach(commentaries) { matchRow($0) }
                        Divider()
                        sectionTitle("Diccionarios y léxicos", count: dictionaries.count)
                        if controller.searchedTerms.isEmpty { Text(L("Añade palabras para consultar diccionarios y léxicos.")).foregroundStyle(.secondary) }
                        else if controller.dictionaryCount == 0 { Text(L("No hay diccionarios ni léxicos disponibles.")).foregroundStyle(.secondary) }
                        else if controller.completed && dictionaries.isEmpty { Text(L("No se encontraron coincidencias verificadas.")).foregroundStyle(.secondary) }
                        ForEach(dictionaries) { matchRow($0) }
                        Divider()
                        sectionTitle("Referencias en recursos", count: controller.references?.results.count ?? 0)
                        if let report = controller.references {
                            if !report.complete { Text(L("La búsqueda de referencias no está completa.")).font(.caption).foregroundStyle(.secondary) }
                            if controller.referenceSourceCount == 0 { Text(L("No hay recursos disponibles para buscar referencias.")).foregroundStyle(.secondary) }
                            else if report.complete && report.results.isEmpty { Text(L("No se encontraron referencias explícitas.")).foregroundStyle(.secondary) }
                            ForEach(report.results) { result in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(result.sourceTitle).font(.headline); Spacer()
                                        if let destination = result.resourceDestination { Button(L("Abrir")) { workspace.openSearchResult(destination) } }
                                    }
                                    Text(result.mention.label).font(.caption).foregroundStyle(.secondary)
                                    Text(result.snippet.text).textSelection(.enabled)
                                }
                            }
                        }
                        if !controller.failures.isEmpty || !(controller.references?.warnings.isEmpty ?? true) || !(controller.references?.resources.isEmpty ?? true) {
                            Divider()
                            DisclosureGroup(L("Advertencias")) {
                                Text(warningLines.joined(separator: "\n"))
                                    .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 250, maxHeight: .infinity)
            }
        }.padding(16)
            .onChange(of: controller.passage) { controller.clear() }
            .onChange(of: controller.terms) { controller.clear() }
            .onChange(of: controller.referenceResourceID) { controller.clear() }
            .onChange(of: workspace.availableResources) { controller.clear() }
            .onDisappear { controller.clear() }
    }
    private var warningLines: [String] {
        var lines = controller.failures + (controller.references?.warnings ?? [])
        for resource in controller.references?.resources ?? [] {
            lines.append(resource.title + ": " + L(resource.statusKey))
            lines += resource.details.map { L($0) }
        }
        return lines
    }
    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack { Text(L(title)).font(.headline); Spacer(); Text(String(count)).foregroundStyle(.secondary) }
    }
    private func matchRow(_ item: PassageGuideMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.match.resource.title).font(.headline); Spacer()
                Button(L("Abrir")) {
                    workspace.error = nil; workspace.openKeyLink(item.match)
                    if let error = workspace.error { openingError = error; workspace.error = nil }
                    else { workspace.activeTool = nil }
                }
            }
            Text(item.term).font(.caption).foregroundStyle(.secondary)
            Text(item.match.excerpt).textSelection(.enabled)
        }
    }
}
