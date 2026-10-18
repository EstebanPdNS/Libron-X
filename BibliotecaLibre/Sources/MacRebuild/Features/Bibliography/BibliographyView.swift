import SwiftUI
import LibronixCore

struct BibliographyView:View {
    @Bindable var workspace:StudyWorkspace
    @Bindable var controller:BibliographyController
    @RebuildViewState private var filter=""
    @RebuildViewState private var showsSelection=false
    @RebuildViewState private var showsDetails=false
    private var filtered:[LibraryResource] {
        workspace.resources.filter { filter.isEmpty || (LibronMetadata.deriving($0).searchText + " " + $0.fileName).localizedStandardContains(filter) }
    }
    private var selection:Binding<Set<String>> { .init(get:{ Set(controller.selected.keys) },set:{ controller.setSelection($0) }) }
    private var entry:BibliographyEntry? { controller.report?.entries.first { $0.id == controller.selectedResultID } }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker(L("Ámbito"),selection:$controller.kind) {
                    Text(L("Toda la biblioteca")).tag(BibliographyScope.Kind.library)
                    Text(L("Colecciones")).tag(BibliographyScope.Kind.collections)
                    Text(L("Selección")).tag(BibliographyScope.Kind.selection)
                }.disabled(controller.isLoading)
                Button(L("Generar bibliografía")) { showsSelection=false;updateContext();controller.run() }.disabled(controller.isLoading)
                if controller.isLoading { ProgressView().controlSize(.small);Button(L("Cancelar")) { controller.cancel() } }
            }
            if controller.kind == .collections {
                List {
                    ForEach(workspace.collections.sets) { collection in
                        Toggle(collection.name,isOn:.init(get:{ controller.collectionIDs.contains(collection.id) },set:{ enabled in
                            if enabled { controller.collectionIDs.insert(collection.id) } else { controller.collectionIDs.remove(collection.id) }
                        }))
                    }
                }.frame(height:100).accessibilityLabel(L("Colecciones de la bibliografía")).disabled(controller.isLoading)
            }
            if controller.kind == .selection {
                DisclosureGroup(L("Elegir recursos"),isExpanded:$showsSelection) {
                    VStack(alignment:.leading,spacing:6) {
                        TextField(L("Filtrar recursos"),text:$filter).macInputStyle()
                        List(filtered,selection:selection) { resource in
                            VStack(alignment:.leading) { Text(resource.title);Text(resource.fileName).font(.caption).foregroundStyle(.secondary) }.tag(resource.id)
                        }.frame(height:120).accessibilityLabel(L("Selección bibliográfica"))
                        HStack {
                            Button(L("Seleccionar visibles")) { controller.select(filtered) }
                            Button(L("Vaciar selección")) { controller.clearSelection() }
                            Text(LF("{count} recursos",["count":String(controller.selected.count)])).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(controller.isLoading)
            }
            Text(L("Se usan los metadatos del catálogo, incluidos los recursos ocultos. Los datos desconocidos no se completan."))
                .font(.caption).foregroundStyle(.secondary)
            if let report=controller.report {
                Text(BibliographyReportRenderer.scopeTitle(report,BibliographyLocalization.labels)).font(.headline)
                HStack {
                    ResourceCitationStylePicker().frame(width:230)
                    Button(L("Copiar cita del recurso")) {
                        if let entry,let resource=workspace.resources.first(where:{ $0.id == entry.id }) { ResourceCitationActions.copy([resource]) }
                    }.disabled(entry == nil || !controller.canExport)
                }
                if let entry {
                    CitationPreview(entry:entry)
                }
                HStack {
                    Text(LF("{included} de {requested} recursos · {unknown} campos desconocidos",[
                        "included":String(report.entries.count),"requested":String(report.scope.requestedCount),"unknown":String(report.unknownFieldCount)]))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker(L("Orden"),selection:$controller.order) {
                        ForEach(BibliographyOrder.allCases,id:\.self) { Text(L($0.title)).tag($0) }
                    }.frame(width:200).disabled(controller.isLoading)
                }
                if controller.configurationChanged {
                    Text(L("El ámbito o el catálogo cambió. Genera la bibliografía de nuevo para copiarla o exportarla."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Table(report.entries,selection:$controller.selectedResultID) {
                    TableColumn(L("Título")) { entry in Text(entry.field(.title).text.isEmpty ? L("Desconocido") : entry.field(.title).text) }.width(min:180,ideal:250)
                    TableColumn(L("Autor")) { entry in Text(entry.field(.authors).text.isEmpty ? L("Desconocido") : entry.field(.authors).text) }.width(min:120,ideal:180)
                    TableColumn(L("Año")) { entry in Text(entry.field(.year).text.isEmpty ? L("Desconocido") : entry.field(.year).text) }.width(min:65,ideal:85)
                    TableColumn(L("Edición")) { entry in Text(entry.field(.edition).text.isEmpty ? L("Desconocido") : entry.field(.edition).text) }.width(min:80,ideal:120)
                }.frame(minHeight:180).accessibilityLabel(L("Informe bibliográfico"))
                if let entry {
                    DisclosureGroup(L("Datos de la edición"),isExpanded:$showsDetails) {
                        ScrollView {
                            Grid(alignment:.leading,horizontalSpacing:14,verticalSpacing:5) {
                                ForEach(entry.fields,id:\.field) { field in
                                    GridRow {
                                        Text(L(field.field.title)).foregroundStyle(.secondary)
                                        Text(field.values.isEmpty ? L("Desconocido") : field.text).textSelection(.enabled)
                                        Text(L(field.certainty.title)).foregroundStyle(field.certainty == .inferred ? .orange : .secondary).font(.caption)
                                    }
                                }
                                GridRow { Text(L("Recurso")).foregroundStyle(.secondary);Text(entry.fileName + " · " + entry.format.displayName).textSelection(.enabled) }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }.frame(maxHeight:130)
                    }
                }
                if !report.scope.issues.isEmpty {
                    DisclosureGroup(L("Bibliografía con miembros pendientes")) {
                        ScrollView { Text(report.scope.issues.map { $0.title + " · " + (BibliographyLocalization.labels.reasons[$0.reason] ?? $0.reason.rawValue) }.joined(separator:"\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight:80)
                    }
                }
                HStack {
                    Button(L("Copiar informe")) { BibliographyExportActions.copy(controller,workspace:workspace) }.disabled(!controller.canExport)
                    Menu(L("Exportar bibliografía")) {
                        ForEach(BibliographyExportKind.allCases,id:\.self) { kind in
                            Button(L(kind.title)) { BibliographyExportActions.export(controller,kind:kind,workspace:workspace) }
                        }
                    }.disabled(!controller.canExport)
                }
            } else {
                Text(L("Genera una bibliografía para consultar los datos de las ediciones.")).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            if let error=controller.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        }.padding(16)
            .onAppear { updateContext() }
            .onChange(of:showsSelection) { if showsSelection { showsDetails=false } }
            .onChange(of:showsDetails) { if showsDetails { showsSelection=false } }
            .onChange(of:workspace.resources) { updateContext() }
            .onChange(of:workspace.collections.sets) { updateContext() }
            .onChange(of:workspace.collections.loadError) { updateContext() }
            .onDisappear { controller.cancel() }
    }
    private func updateContext() { controller.updateContext(.init(resources:workspace.resources,collections:workspace.collections.sets,collectionsError:workspace.collections.loadError)) }
}
