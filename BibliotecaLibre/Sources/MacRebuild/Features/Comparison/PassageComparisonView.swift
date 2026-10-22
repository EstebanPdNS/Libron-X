import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LibronixCore

struct PassageComparisonView: View {
    @Bindable var workspace: StudyWorkspace
    @Bindable var controller: PassageComparisonController
    @RebuildViewState private var selectionExpanded = true
    @RebuildViewState private var actionError: String?
    private var bibles: [LibraryResource] { workspace.resourcePriorities.ordered(workspace.availableResources, in: .init(kind: .bible)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("Pasaje, capítulo o libro"), text: $controller.reference).macInputStyle()
                    .onSubmit(run)
                if controller.isLoading { Button(L("Cancelar"), action: controller.cancel) }
                else { Button(L("Comparar"), action: run).disabled(controller.reference.isEmpty || controller.selectedIDs.isEmpty) }
            }
            DisclosureGroup(L("Versiones bíblicas"), isExpanded: $selectionExpanded) {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(bibles) { resource in
                            Toggle(isOn: Binding(get: { controller.selectedIDs.contains(resource.id) }, set: { selected in
                                controller.invalidate()
                                if selected { controller.selectedIDs.insert(resource.id) }
                                else { controller.selectedIDs.remove(resource.id) }
                                if !controller.selectedIDs.contains(controller.baseID) { controller.baseID = bibles.first { controller.selectedIDs.contains($0.id) }?.id ?? "" }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(resource.title)
                                    Text(resource.libron?.edition ?? resource.fileName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if bibles.isEmpty { Text(L("No hay Biblias compatibles en la biblioteca.")) }
                    }
                }.frame(maxHeight: 150)
            }
            Picker(L("Versión base"), selection: $controller.baseID) {
                Text(L("Selecciona un recurso")).tag("")
                ForEach(bibles.filter { controller.selectedIDs.contains($0.id) }) { Text($0.title).tag($0.id) }
            }.disabled(controller.isLoading)
            HStack {
                Toggle(L("Mayúsculas"), isOn: $controller.options.caseSensitive)
                Toggle(L("Acentos"), isOn: $controller.options.accentSensitive)
                Toggle(L("Puntuación"), isOn: $controller.options.punctuationSensitive)
            }.disabled(controller.isLoading)
            Text(L("Se comparan las referencias de cada edición. No se convierten las versificaciones. Las diferencias de espacios se omiten."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = controller.error ?? actionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if controller.isLoading { HStack { ProgressView().controlSize(.small); Text(controller.progress).font(.caption) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(controller.editions, id: \.resource.id) { edition in
                        if !edition.complete {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(edition.resource.title).font(.headline)
                                Text(edition.failure.map(L) ?? L("Cobertura parcial: no se puede confirmar la ausencia de versículos."))
                                ForEach(edition.warnings, id: \.self) { Text($0) }
                            }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    ForEach(controller.rows) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(row.reference).font(.headline)
                            ForEach(row.cells) { cell in
                                if let edition = controller.editions.first(where: { $0.resource.id == cell.resourceID }) {
                                    cellView(cell, edition: edition)
                                }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if controller.completed, controller.rows.isEmpty { Text(L("No se encontraron referencias en el rango solicitado.")) }
                }.padding(.vertical, 4)
            }
            HStack {
                Text(LF("{count} referencias", ["count": String(controller.rows.count)])).font(.caption)
                Spacer()
                Button(L("Exportar CSV…"), action: export).disabled(!controller.completed || controller.rows.isEmpty)
            }
        }.padding(16)
            .onAppear {
                if controller.selectedIDs.isEmpty {
                    let initial = bibles.prefix(2)
                    controller.selectedIDs = Set(initial.map(\.id)); controller.baseID = initial.first?.id ?? ""
                }
                if controller.reference.isEmpty { controller.reference = workspace.activeReader?.currentReference ?? "" }
            }
            .onChange(of: controller.reference) { controller.invalidate() }
            .onChange(of: controller.options) { controller.compareAgain() }
            .onChange(of: controller.baseID) { controller.compareAgain() }
            .onChange(of: workspace.availableResources) { controller.invalidate() }
            .onDisappear { controller.cancel() }
    }

    @ViewBuilder private func cellView(_ cell: PassageComparisonRow.Cell, edition: BiblePassageEdition) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(edition.resource.title).font(.subheadline.weight(.semibold))
                if edition.resource.id == controller.baseID { Text(L("Versión base")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let verse = cell.verse { Button(L("Abrir")) { open(verse, edition: edition) } }
            }
            Text(edition.resource.libron?.edition ?? edition.resource.fileName).font(.caption).foregroundStyle(.secondary)
            if let verse = cell.verse {
                Text(highlighted(verse.text, differences: cell.differences)).textSelection(.enabled)
                if let base = controller.editions.first(where: { $0.resource.id == controller.baseID })?.verses.first(where: { $0.key == verse.key }) {
                    ForEach(Array(cell.differences.enumerated()), id: \.offset) { _, difference in
                        if difference.base.length > 0 {
                            Text(L(difference.kind == .omission ? "Omisión" : "Sustitución") + ": " + (base.text as NSString).substring(with: difference.base.nsRange))
                                .font(.caption).foregroundStyle(.secondary).strikethrough().textSelection(.enabled)
                        }
                    }
                }
                if let error = cell.comparisonError { Text(L(error)).font(.caption).foregroundStyle(.secondary) }
            } else { Text(L(edition.complete ? "Versículo ausente en esta edición." : "Versículo sin verificar en esta edición."))
                    .font(.callout).foregroundStyle(.secondary) }
        }
    }
    private func highlighted(_ text: String, differences: [TextDifference]) -> AttributedString {
        let string = NSMutableAttributedString(string: text)
        for difference in differences where difference.compared.length > 0 {
            string.addAttribute(.backgroundColor, value: (difference.kind == .addition ? NSColor.systemGreen : NSColor.systemOrange).withAlphaComponent(0.22), range: difference.compared.nsRange)
        }
        return AttributedString(string)
    }
    private func run() { actionError = nil; selectionExpanded = false; controller.run(resources: workspace.availableResources) }
    private func open(_ verse: BiblePassageVerse, edition: BiblePassageEdition) {
        do {
            try controller.open(verse, edition: edition, in: workspace)
            workspace.activeTool = nil
        } catch { actionError = error.localizedDescription }
    }
    private func export() {
        do {
            let csv = try controller.exportCSV(), panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Libron-X-comparison.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try controller.verifySources(); try Data(csv.utf8).write(to: url, options: .atomic)
        } catch { actionError = error.localizedDescription }
    }
}
