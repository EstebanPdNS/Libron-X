import SwiftUI

/// The same reading-output actions are available in Bible and dictionary panes.
struct ReaderOutputMenuItems: View {
    let reader: ReaderSession
    let workspace: StudyWorkspace
    @ViewBuilder var body: some View {
        Button(L("Copiar selección o artículo")) { workspace.activate(reader); ReaderOutputActions.copy(reader, workspace: workspace) }
        Button(L("Agregar a favoritos")) { workspace.activate(reader); workspace.addFavorite() }
        Button(L("Agregar nota sobre la selección")) { perform { workspace.addNoteForSelection(reader) } }
        Divider()
        Menu(L("Exportar")) {
            Button(L("Texto…")) { perform { ReaderOutputActions.export(reader, type: "txt", workspace: workspace) } }
            Button(L("Texto con imágenes (RTFD)…")) { perform { ReaderOutputActions.export(reader, type: "rtfd", workspace: workspace) } }.disabled(reader.page?.oeb != nil)
            Button(L("HTML…")) { perform { ReaderOutputActions.export(reader, type: "html", workspace: workspace) } }
            Button(L("PDF…")) { perform { ReaderOutputActions.export(reader, type: "pdf", workspace: workspace) } }
            if reader.page?.oeb != nil { Button(L("Archivo web…")) { perform { ReaderOutputActions.export(reader, type: "webarchive", workspace: workspace) } } }
        }
        Button(L("Imprimir…")) { perform { ReaderOutputActions.printReader(reader, workspace: workspace) } }
    }
    private func perform(_ action: () -> Void) { workspace.activate(reader); action() }
}
