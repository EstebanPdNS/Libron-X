import AppKit
import SwiftUI
import LibronixCore

struct BibleCopyToolView: View {
    @Bindable var workspace: StudyWorkspace
    @RebuildViewState private var reference = ""
    @RebuildViewState private var resourceID = ""
    @RebuildViewState private var paragraphStyle = BibleCopyParagraphPolicy.perVerse
    @RebuildViewState private var citation = true
    @RebuildViewState private var footnotes = false
    @RebuildViewState private var result = ""
    @RebuildViewState private var error: String?
    @RebuildViewState private var isLoading = false
    @RebuildViewState private var task: Task<Void, Never>?
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
            ScrollView { Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
            HStack { Spacer(); Button(L("Copiar")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }.disabled(result.isEmpty) }
        }.padding(16)
            .onAppear {
                let active = workspace.activeReader
                resourceID = workspace.availableResources.contains { $0.id == active?.resource.id } ? active?.resource.id ?? "" : ""
                reference = active?.currentReference ?? ""
            }
            .onChange(of: workspace.availableResources.map(\.id)) {
                if !workspace.availableResources.contains(where: { $0.id == resourceID }) {
                    task?.cancel(); resourceID = ""; result = ""; isLoading = false
                }
            }
            .onDisappear { task?.cancel() }
            .onChange(of: reference) { task?.cancel(); result = ""; isLoading = false }
            .onChange(of: resourceID) { task?.cancel(); result = ""; isLoading = false }
            .onChange(of: paragraphStyle) { task?.cancel(); result = ""; isLoading = false }
            .onChange(of: citation) { task?.cancel(); result = ""; isLoading = false }
            .onChange(of: footnotes) { task?.cancel(); result = ""; isLoading = false }
    }
    private func prepare() {
        task?.cancel()
        guard let resource = workspace.availableResources.first(where: { $0.id == resourceID }) else { return }
        let requested = reference
        var style = BibleCopyOutputStyle(name: "Copiar versículos")
        style.paragraphs = paragraphStyle; style.citation = citation; style.copyFootnotes = footnotes
        error = nil; result = ""; isLoading = true
        task = Task {
            do {
                let passage = try BibleCopyPassage.parse(requested)
                let document = try await BibleCopyService().prepare(resource, passage: passage, abbreviation: resource.location.deletingPathExtension().lastPathComponent, includeFootnotes: footnotes)
                let formatted = try BibleCopyFormatter.format(document, style: style, referenceLanguage: .spanish)
                guard !Task.isCancelled else { return }
                result = formatted.plainText; isLoading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; isLoading = false } }
        }
    }
}
