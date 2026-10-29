import AppKit
import SwiftUI
import LibronixCore
import LibronixOutputMac
import UniformTypeIdentifiers

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
    private var resources: [LibraryResource] { workspace.availableResources.filter { $0.format == .legacyLSF || ([.eSwordSQLite, .libronixLLS].contains($0.format) && LibronMetadata.deriving($0).resourceType == "Biblia") } }
    private var chosenStyle: BibleCopyOutputStyle {
        workspace.personal.bibleCopyState.styles.first { $0.id == workspace.personal.bibleCopyState.selectedStyleID }!
    }
    private var chosenStyleID: Binding<UUID> {
        Binding(get: { chosenStyle.id }, set: { value in
            do { try workspace.personal.editBibleCopyState { $0.selectedStyleID = value } }
            catch { self.error = error.localizedDescription }
        })
    }
    private var referenceLanguage: Binding<BibleCopyReferenceLanguage> {
        Binding(get: { workspace.personal.bibleCopyState.referenceLanguage }, set: { language in
            do { try workspace.personal.editBibleCopyState { $0.referenceLanguage = language } }
            catch { self.error = error.localizedDescription }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Biblia")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Biblia"), value: resources.first { $0.id == resourceID }?.title ?? L("Selecciona un recurso"), selection: $resourceID) {
                        Text(L("Selecciona un recurso")).tag("")
                        ForEach(resources) { Text($0.title).tag($0.id) }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Plantilla")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Plantilla"), value: chosenStyle.preset == nil ? chosenStyle.name : L(chosenStyle.name), selection: chosenStyleID) {
                        ForEach(workspace.personal.bibleCopyState.styles) { style in
                            Text(style.preset == nil ? style.name : L(style.name)).tag(style.id)
                        }
                    }
                }
                Button { showStyles = true } label: { Label(L("Gestionar plantillas…"), systemImage: "slider.horizontal.3").labelStyle(.iconOnly) }.help(L("Gestionar plantillas…"))
            }
            HStack(spacing: 12) {
                TextField(L("Pasaje, por ejemplo Juan 1:1-5"), text: $reference).macInputStyle().onSubmit(prepare)
                Button(L("Vista previa"), action: prepare).disabled(isLoading || resourceID.isEmpty || reference.isEmpty)
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Opciones de copia")).font(.headline)
                    Text(L("Párrafos")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Párrafos"), value: paragraphStyle.localizedTitle, selection: $paragraphStyle) {
                        ForEach(BibleCopyParagraphPolicy.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                    }.disabled(!chosenStyle.bibleTextOnly)
                    Text(L("Idioma de las referencias")).font(.caption).foregroundStyle(.secondary)
                    MacSelectionMenu(L("Idioma de las referencias"), value: referenceLanguage.wrappedValue == .english ? "English" : "Español", selection: referenceLanguage) {
                        Text("English").tag(BibleCopyReferenceLanguage.english)
                        Text("Español").tag(BibleCopyReferenceLanguage.spanish)
                    }
                    Toggle(L("Cita bibliográfica"), isOn: $citation)
                    Toggle(L("Notas al pie"), isOn: $footnotes)
                    if isLoading {
                        HStack { ProgressView().controlSize(.small); Button(L("Cancelar")) { task?.cancel(); isLoading = false } }
                    }
                    Spacer(minLength: 0)
                }.frame(width: 200)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Vista previa")).font(.headline)
                    Group {
                        if let payload { MacAttributedPreview(text: payload.preview) }
                        else {
                            Text(L("Selecciona una Biblia y un pasaje para preparar la copia.")).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).macEditorSurface()
                }
            }.frame(maxHeight: .infinity)
            if let error { Text(L(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer()
                Menu {
                    if let payload {
                        Button("TXT") { export(payload, type: .plainText, extension: "txt", data: Data(payload.text.utf8)) }
                        Button("RTF") { export(payload, type: .rtf, extension: "rtf", data: payload.rtf) }
                        Button("HTML") { export(payload, type: .html, extension: "html", data: payload.html) }
                    }
                } label: { Label(L("Exportar…"), systemImage: "square.and.arrow.up") }.disabled(payload == nil || result.isEmpty)
                Button(L("Copiar")) {
                guard let payload else { return }
                do { try NativeBibleCopyOutput.copy(payload); error = nil }
                catch { self.error = error.localizedDescription }
            }.disabled(payload == nil || result.isEmpty) }
        }.padding(16)
            .onAppear {
                let active = workspace.activeReader
                resourceID = resources.contains { $0.id == active?.resource.id } ? active?.resource.id ?? "" : resources.first?.id ?? ""
                reference = active?.currentReference ?? ""
                loadStyleOptions()
            }
            .onChange(of: resources) {
                clearPreview()
                if !resources.contains(where: { $0.id == resourceID }) {
                    task?.cancel(); resourceID = ""; result = ""; payload = nil; isLoading = false
                }
            }
            .onDisappear { task?.cancel() }
            .onChange(of: reference) { clearPreview() }
            .onChange(of: resourceID) { clearPreview() }
            .onChange(of: paragraphStyle) { clearPreview() }
            .onChange(of: citation) { clearPreview() }
            .onChange(of: footnotes) { clearPreview() }
            .onChange(of: BibleCopyRenderIdentity(chosenStyle)) { loadStyleOptions(); clearPreview() }
            .onChange(of: workspace.personal.bibleCopyState.referenceLanguage) { clearPreview() }
            .sheet(isPresented: $showStyles) { BibleCopyStylesView(workspace: workspace, personal: workspace.personal).modifier(AppInterfaceLanguage()) }
    }
    private func export(_ payload: NativeBibleCopyPayload, type: UTType, extension ext: String, data: Data) {
        let panel = NSSavePanel(); panel.title = L("Exportar copia bíblica")
        panel.allowedContentTypes = [type]; panel.nameFieldStringValue = payload.document.title + "." + ext
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func loadStyleOptions() {
        paragraphStyle = chosenStyle.bibleTextOnly ? chosenStyle.paragraphs : .sourceParagraphs
        citation = chosenStyle.citation; footnotes = chosenStyle.copyFootnotes
    }
    private func clearPreview() { task?.cancel(); result = ""; payload = nil; isLoading = false; error = nil }
    private func prepare() {
        task?.cancel()
        guard let resource = resources.first(where: { $0.id == resourceID }) else { return }
        let requested = reference, language = referenceLanguage.wrappedValue
        var style = chosenStyle
        style.paragraphs = paragraphStyle; style.citation = citation; style.copyFootnotes = footnotes
        error = nil; result = ""; payload = nil; isLoading = true
        task = Task {
            do {
                let passage = try BibleCopyPassage.parse(requested)
                let document = try await WorkspaceBibleCopy.prepare(resource, passage: passage, includeFootnotes: footnotes)
                let formatted = try await BibleCopyFormattingService().format(document, style: style, language: language)
                let output = try NativeBibleCopyOutput.prepare(formatted)
                guard !Task.isCancelled else { return }
                result = output.text; payload = output; isLoading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; isLoading = false } }
        }
    }
}
