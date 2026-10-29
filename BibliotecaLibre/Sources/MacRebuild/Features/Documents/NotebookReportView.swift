import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LibronixCore

/// A snapshot is used throughout the report so a later edit cannot silently
/// change what is exported after the user has reviewed it.
@MainActor enum NotebookReport {
    static func make(document: StudyDocument, selected: Set<UUID>, includeBody: Bool, includeReferences: Bool) throws -> NSAttributedString {
        try document.validate()
        guard document.kind == .notebook, selected.isSubset(of: Set(document.notes.map(\.id))) else {
            throw PersonalStateError.invalid("Las notas seleccionadas ya no están disponibles.")
        }
        let result = NSMutableAttributedString(string: document.title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        for entry in try StudyNoteOrganization.outline(document.notes) where selected.contains(entry.id) {
            result.append(NSAttributedString(string: entry.note.title + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
            if includeReferences, let reference = PersonalReferenceProjection.anchor(entry.note), !reference.isEmpty {
                result.append(NSAttributedString(string: reference + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            }
            if includeBody {
                guard !NoteRichTextCodec.hasUnsupportedHTMLObjects(entry.note) || entry.note.editedRTF != nil else {
                    throw PersonalStateError.invalid("Una nota contiene objetos que no se pueden incluir en el informe sin pérdida.")
                }
                result.append(try NoteRichTextCodec.attributed(entry.note))
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(NSAttributedString(string: "\n"))
            guard result.length <= 16_000_000 else { throw PersonalStateError.tooLarge }
        }
        return result
    }
}

struct NotebookReportView: View {
    let document: StudyDocument
    let initialSelection: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selected: Set<UUID> = []
    @RebuildViewState private var includeBody = true
    @RebuildViewState private var includeReferences = true
    @RebuildViewState private var error: String?
    private var report: NSAttributedString? { try? NotebookReport.make(document: document, selected: selected, includeBody: includeBody, includeReferences: includeReferences) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: "Informe del cuaderno") { dismiss() }
            HStack {
                Button(L("Seleccionar todo")) { selected = Set(document.notes.map(\.id)) }
                Button(L("Deseleccionar todo")) { selected = [] }
                Spacer()
                Toggle(L("Contenido"), isOn: $includeBody)
                Toggle(L("Referencias"), isOn: $includeReferences)
            }
            List((try? StudyNoteOrganization.outline(document.notes)) ?? []) { entry in
                Toggle(isOn: Binding(get: { selected.contains(entry.id) }, set: { on in
                    if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
                })) { Text(entry.note.title).padding(.leading, CGFloat(min(entry.depth, 8)) * 12) }
            }.frame(minHeight: 130, idealHeight: 180, maxHeight: 180)
            Text(L("Vista previa")).font(.headline)
            ScrollView {
                if let report { Text(BibleCopyPreview.text(report)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                else { Text(L("No se pudo preparar el informe con estas opciones.")).foregroundStyle(.secondary).padding(12) }
            }.frame(minHeight: 140).macEditorSurface()
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("Imprimir…"), action: printReport).disabled(selected.isEmpty || report == nil)
                Menu(L("Exportar…")) {
                    Button("TXT") { export("txt", type: .plainText) }
                    Button("RTFD") { export("rtfd", type: .rtfd) }
                    Button("PDF") { export("pdf", type: .pdf) }
                }.disabled(selected.isEmpty || report == nil)
            }
        }.padding(16).frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 650)
            .modifier(MacPanelControlPresentation())
            .onAppear { selected = initialSelection.isEmpty ? Set(document.notes.map(\.id)) : initialSelection }
    }
    private func export(_ ext: String, type: UTType) {
        guard let report else { return }
        let panel = NSSavePanel(); panel.title = L("Exportar informe"); panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = document.title + "." + ext
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try ReaderOutputActions.write(report, to: url, type: ext) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func printReport() {
        guard let report else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let operation = NSPrintOperation(view: ReaderOutputActions.printView(report, info: info), printInfo: info)
        operation.showsPrintPanel = true; operation.showsProgressPanel = true; operation.run()
    }
}
