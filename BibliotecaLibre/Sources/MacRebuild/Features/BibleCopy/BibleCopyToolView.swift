import AppKit
import SwiftUI
import LibronixCore
import LibronixOutputMac

@MainActor enum BibleCopyPreview {
    static func text(_ original: NSAttributedString) -> AttributedString {
        let copy = NSMutableAttributedString(attributedString: original)
        let full = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if let color = value as? NSColor, color == .black { copy.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        return AttributedString(copy)
    }
}

struct BibleCopyToolView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var reference = ""
    @RebuildViewState private var resourceID = ""
    @RebuildViewState private var paragraphStyle = BibleCopyParagraphPolicy.perVerse
    @RebuildViewState private var citation = true
    @RebuildViewState private var footnotes = false
    @RebuildViewState private var result = ""
    @RebuildViewState private var payload: NativeBibleCopyPayload?
    @RebuildViewState private var error: String?
    @RebuildViewState private var isLoading = false
    @RebuildViewState private var task: Task<Void, Never>?
    @RebuildViewState private var showStyles = false
    private var chosenStyle: BibleCopyOutputStyle? {
        workspace.personal.bibleCopyState.customStyles.first { $0.id == workspace.personal.bibleCopyState.selectedStyleID }
    }
    private var chosenStyleID: Binding<UUID?> {
        Binding(get: { chosenStyle?.id }, set: { value in
            do { try workspace.personal.editBibleCopyState { $0.selectedStyleID = value ?? BibleCopyOutputStyle.defaults[1].id } }
            catch { self.error = error.localizedDescription }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Biblia"), selection: $resourceID) {
                Text(L("Selecciona un recurso")).tag("")
                ForEach(workspace.availableResources.filter { $0.format == .legacyLSF }) { resource in Text(resource.title).tag(resource.id) }
            }
            HStack {
                TextField(L("Pasaje, por ejemplo Juan 1:1-5"), text: $reference).macInputStyle().onSubmit(prepare)
                Button(L("Vista previa"), action: prepare).disabled(isLoading || resourceID.isEmpty || reference.isEmpty)
            }
            HStack {
                Picker(L("Plantilla"), selection: chosenStyleID) {
                    Text(L("Formato actual")).tag(Optional<UUID>.none)
                    ForEach(workspace.personal.bibleCopyState.customStyles) { Text($0.name).tag(Optional($0.id)) }
                }
                Button(L("Gestionar plantillas…")) { showStyles = true }
            }.disabled(isLoading)
            HStack {
                Picker(L("Párrafos"), selection: $paragraphStyle) {
                    Text(L("Por versículo")).tag(BibleCopyParagraphPolicy.perVerse)
                    Text(L("Del original")).tag(BibleCopyParagraphPolicy.sourceParagraphs)
                    Text(L("Un solo párrafo")).tag(BibleCopyParagraphPolicy.perPassage)
                }
                Toggle(L("Cita bibliográfica"), isOn: $citation)
                Toggle(L("Notas al pie"), isOn: $footnotes)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if isLoading { HStack { ProgressView().controlSize(.small); Button(L("Cancelar")) { task?.cancel(); isLoading = false } } }
            ScrollView {
                Group {
                    if let payload { Text(BibleCopyPreview.text(payload.preview)) }
                    else { Text(result) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
                .macEditorSurface()
            HStack { Spacer(); Button(L("Copiar")) {
                guard let payload else { return }
                do { try NativeBibleCopyOutput.copy(payload); error = nil }
                catch { self.error = error.localizedDescription }
            }.disabled(payload == nil || result.isEmpty) }
        }.padding(16)
            .onAppear {
                let active = workspace.activeReader
                resourceID = workspace.availableResources.contains { $0.id == active?.resource.id } ? active?.resource.id ?? "" : ""
                reference = active?.currentReference ?? ""
            }
            .onChange(of: workspace.availableResources.map(\.id)) {
                if !workspace.availableResources.contains(where: { $0.id == resourceID }) {
                    task?.cancel(); resourceID = ""; result = ""; payload = nil; isLoading = false
                }
            }
            .onDisappear { task?.cancel() }
            .onChange(of: reference) { clearPreview() }
            .onChange(of: resourceID) { clearPreview() }
            .onChange(of: paragraphStyle) { clearPreview() }
            .onChange(of: citation) { clearPreview() }
            .onChange(of: footnotes) { clearPreview() }
            .onChange(of: workspace.personal.bibleCopyState) { clearPreview() }
            .sheet(isPresented: $showStyles) { BibleCopyStylesView(workspace: workspace, personal: workspace.personal).modifier(AppInterfaceLanguage()) }
    }
    private func clearPreview() { task?.cancel(); result = ""; payload = nil; isLoading = false }
    private func prepare() {
        task?.cancel()
        guard let resource = workspace.availableResources.first(where: { $0.id == resourceID }) else { return }
        let requested = reference
        var style = chosenStyle ?? BibleCopyOutputStyle(name: "Copiar versículos")
        style.paragraphs = paragraphStyle; style.citation = citation; style.copyFootnotes = footnotes
        error = nil; result = ""; payload = nil; isLoading = true
        task = Task {
            do {
                let passage = try BibleCopyPassage.parse(requested)
                let document = try await BibleCopyService().prepare(resource, passage: passage, abbreviation: resource.location.deletingPathExtension().lastPathComponent, includeFootnotes: footnotes)
                let formatted = try BibleCopyFormatter.format(document, style: style, referenceLanguage: .spanish)
                let output = try NativeBibleCopyOutput.prepare(formatted)
                guard !Task.isCancelled else { return }
                result = output.text; payload = output; isLoading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; isLoading = false } }
        }
    }
}
