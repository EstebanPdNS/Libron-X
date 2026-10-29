import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LibronixCore

/// A snapshot is used throughout the report so a later edit cannot silently
/// change what is exported after the user has reviewed it.
@MainActor enum NotebookReport {
    static func make(document: StudyDocument, selected: Set<UUID>, includeBody: Bool, includeReferences: Bool,
                     includeCitations: Bool = false, resources: [LibraryResource] = [], citationStyle: ResourceCitationStyle = .catalog) throws -> NSAttributedString {
        try document.validate()
        guard document.kind.usesNotes, selected.isSubset(of: Set(document.notes.map(\.id))) else {
            throw PersonalStateError.invalid("Las notas seleccionadas ya no están disponibles.")
        }
        let sourceIDs = Set(document.notes.filter { selected.contains($0.id) }.compactMap { $0.effectiveAnchor.location?.resourceID })
        let citations = includeCitations ? try ResourceCitationActions.entries(resources.filter { sourceIDs.contains($0.id) }) : []
        let byID = Dictionary(uniqueKeysWithValues: citations.map { ($0.resourceID, $0) })
        let result = NSMutableAttributedString(string: document.title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        if let metadata = document.sermon {
            for row in SermonMetadataPresentation.rows(metadata) where includeReferences || row.key != "Pasajes bíblicos" {
                result.append(NSAttributedString(string: L(row.key) + ": " + row.value + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            }
            result.append(NSAttributedString(string: "\n"))
        }
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
            if includeCitations {
                let anchor = entry.note.effectiveAnchor
                let citation: String?
                if let location = anchor.location {
                    if let source = byID[location.resourceID], source.format == location.format,
                       source.legacyIdentifier == location.legacyIdentifier {
                        citation = ResourceCitation.text(source, style: citationStyle, unknown: L("Desconocido"))
                    } else { citation = L("Fuente no disponible en la biblioteca.") }
                } else if anchor.kind != .general {
                    citation = L("La fuente original de esta nota no está identificada.")
                } else { citation = nil }
                if let citation {
                    result.append(NSAttributedString(string: citation + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
                }
            }
            result.append(NSAttributedString(string: "\n"))
            guard result.length <= 16_000_000 else { throw PersonalStateError.tooLarge }
        }
        return result
    }
    static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.isVerticallyCentered = false; info.isHorizontallyCentered = false
        return info
    }
}

struct NotebookReportView: View {
    let document: StudyDocument
    @RebuildViewState private var resources: [LibraryResource]
    @Environment(\.dismiss) private var dismiss
    @RebuildViewState private var selected: Set<UUID>
    @RebuildViewState private var includeBody = true
    @RebuildViewState private var includeReferences = true
    @RebuildViewState private var includeCitations = true
    @RebuildViewState private var citationStyle = ResourceCitationActions.style
    @RebuildViewState private var preview: Result<NSAttributedString, Error>?
    @RebuildViewState private var error: String?
    init(document: StudyDocument, initialSelection: Set<UUID>, resources: [LibraryResource] = []) {
        self.document = document; _resources = RebuildViewState(wrappedValue: resources)
        _selected = RebuildViewState(wrappedValue: initialSelection.isEmpty ? Set(document.notes.map(\.id)) : initialSelection)
    }
    private var report: NSAttributedString? {
        guard case .success(let value)? = preview else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacToolHeader(title: document.kind == .sermon ? "Informe del sermón" : "Informe del cuaderno") { dismiss() }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Incluir en el informe")).font(.headline)
                    Toggle(L("Contenido de la nota"), isOn: $includeBody)
                    Toggle(L("Referencias"), isOn: $includeReferences)
                    Toggle(L("Citas bibliográficas"), isOn: $includeCitations)
                    if includeCitations {
                        MacSelectionMenu(L("Estilo de cita"), value: L(citationStyle.title), selection: $citationStyle) {
                            ForEach(ResourceCitationStyle.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                        }
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Text(L("Notas")).font(.headline)
                        Spacer()
                        Button { selected = Set(document.notes.map(\.id)) } label: {
                            Label(L("Seleccionar todo"), systemImage: "checkmark.circle").labelStyle(.iconOnly)
                        }.help(L("Seleccionar todo"))
                        Button { selected = [] } label: {
                            Label(L("Deseleccionar todo"), systemImage: "circle").labelStyle(.iconOnly)
                        }.help(L("Deseleccionar todo"))
                    }
                    List((try? StudyNoteOrganization.outline(document.notes)) ?? []) { entry in
                        Toggle(isOn: Binding(get: { selected.contains(entry.id) }, set: { on in
                            if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
                        })) { Text(verbatim: entry.note.title).padding(.leading, CGFloat(min(entry.depth, 8)) * 12) }
                    }.frame(minHeight: 130).listStyle(.inset)
                }.frame(width: 236)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Vista previa")).font(.headline)
                    ScrollView {
                        Group {
                            if selected.isEmpty {
                                Text(L("Selecciona las notas que quieras incluir.")).foregroundStyle(.secondary)
                            } else {
                                switch preview {
                                case .success(let report): Text(BibleCopyPreview.text(report)).textSelection(.enabled)
                                case .failure(let failure): Text(L(failure.localizedDescription)).foregroundStyle(.secondary).textSelection(.enabled)
                                case nil: ProgressView()
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).macEditorSurface()
                }
            }.frame(maxHeight: .infinity)
            if let error { Text(L(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L("Imprimir…"), action: printReport).disabled(selected.isEmpty || report == nil)
                Menu { Button("TXT") { export("txt", type: .plainText) }
                    Button("RTFD") { export("rtfd", type: .rtfd) }
                    Button("PDF") { export("pdf", type: .pdf) }
                } label: { Label(L("Exportar…"), systemImage: "square.and.arrow.up") }
                    .disabled(selected.isEmpty || report == nil)
            }
        }.padding(16).frame(minWidth: 700, idealWidth: 820, minHeight: 520, idealHeight: 620)
            .modifier(MacPanelControlPresentation())
            .onAppear(perform: refresh)
            .onChange(of: selected) { refresh() }.onChange(of: includeBody) { refresh() }
            .onChange(of: includeReferences) { refresh() }.onChange(of: includeCitations) { refresh() }
            .onChange(of: citationStyle) { refresh() }
    }
    private func refresh() {
        error = nil
        preview = Result { try NotebookReport.make(document: document, selected: selected,
            includeBody: includeBody, includeReferences: includeReferences, includeCitations: includeCitations,
            resources: resources, citationStyle: citationStyle) }
    }
    private func export(_ ext: String, type: UTType) {
        guard let report else { return }
        let panel = NSSavePanel(); panel.title = L("Exportar informe"); panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = document.title + "." + ext
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try ReaderOutputActions.write(report, to: url, type: ext, printInfo: NotebookReport.printInfo()) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func printReport() {
        guard let report else { return }
        let info = NotebookReport.printInfo()
        let operation = NSPrintOperation(view: ReaderOutputActions.printView(report, info: info), printInfo: info)
        operation.showsPrintPanel = true; operation.showsProgressPanel = true; operation.run()
    }
}
