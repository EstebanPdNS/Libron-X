import AppKit
import CryptoKit
import LibronixCore
import LibronixOutputMac
import SwiftUI
import UniformTypeIdentifiers

struct BibleCopyWorkspace:View {
    @Bindable var model:BibleCopyModel
    let resources:[LibraryResource]
    @ViewState private var editing:BibleCopyOutputStyle?
    @ViewState private var original:BibleCopyOutputStyle?
    @ViewState private var deleteConfirmation=false
    private var preparationKey:String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let style=model.style.flatMap{try? encoder.encode($0)}.map{String(decoding:$0,as:UTF8.self)} ?? ""
        return [model.passage,model.resourceID ?? "",model.referenceLanguage.rawValue,style].joined(separator:"\u{001f}")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Copiar versículos bíblicos").font(.title2)
            HStack(alignment:.top,spacing:24) {
                VStack(alignment:.leading,spacing:12) {
                    TextField("Pasaje",text:$model.passage,prompt:Text("Juan 1:1–2"))
                        .textFieldStyle(.roundedBorder).onSubmit{model.prepare(resources:resources)}
                    Picker("Edición",selection:$model.resourceID) {
                        Text("Seleccionar edición").tag(Optional<String>.none)
                        ForEach(resources.filter{$0.format == .legacyLSF && !$0.isHelp}) { resource in Text(resource.title).tag(Optional(resource.id)) }
                    }
                    Picker("Idioma de referencias",selection:$model.referenceLanguage) {
                        Text("Inglés").tag(BibleCopyReferenceLanguage.english);Text("Español").tag(BibleCopyReferenceLanguage.spanish)
                    }
                    Text("Un versículo, un capítulo o un rango: Juan 1:1, Juan 1, Juan 1:51–2:2.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity)
                VStack(alignment:.leading,spacing:12) {
                    Picker("Estilo",selection:$model.styleID) {
                        ForEach(model.settings.value.styles) { style in Text(style.name).tag(style.id) }
                    }
                    HStack {
                        Button("Nuevo…") {
                            var draft=model.style ?? BibleCopyOutputStyle();draft.id=UUID();draft.preset=nil;draft.name="Nuevo estilo"
                            original=nil;editing=draft
                        }
                        Button("Modificar…") { original=model.style;editing=model.style }.disabled(model.style?.preset != nil)
                        Button("Borrar…") { deleteConfirmation=true }.disabled(model.style?.preset != nil)
                        Menu("Más") {
                            Button("Importar estilo…",action:importStyle)
                            Button("Exportar estilo…",action:exportStyle).disabled(model.style==nil)
                        }
                    }
                    Text("Destino: portapapeles de macOS. Pega con ⌘V en tu documento.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Mantener abierta",isOn:$model.keepOpen)
                }.frame(maxWidth:.infinity)
            }
            Divider()
            HStack {
                Text("Vista previa").font(.headline)
                if model.isPreparing { ProgressView().controlSize(.small);Text("Preparando…").foregroundStyle(.secondary) }
                Spacer()
                if let document=model.document { Text("\(document.verses.count) versículos").foregroundStyle(.secondary) }
            }
            if let preview=model.payload?.preview { BibleCopyPreviewText(text:preview).frame(maxWidth:.infinity,maxHeight:.infinity) }
            else {
                ContentUnavailableView(model.isPreparing ? "Preparando el pasaje":"Sin vista previa",systemImage:"doc.on.clipboard",
                    description:Text(model.errorMessage ?? "Escribe un pasaje y selecciona su edición y estilo."))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            if let message=model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error=model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Actualizar vista previa") { model.prepare(resources:resources) }.disabled(model.isPreparing)
                Spacer()
                Button("Cerrar",action:model.close).keyboardShortcut(.cancelAction)
                Button("Copiar") { model.copy() }.keyboardShortcut(.defaultAction)
                    .disabled(!model.canCopy)
            }
        }.padding(24).frame(minWidth:900,minHeight:650)
        .task(id:preparationKey) {
            do { try await Task.sleep(for:.milliseconds(200));try Task.checkCancellation();model.prepare(resources:resources) }
            catch {}
        }
        .onDisappear{model.invalidate()}
        .onChange(of:model.settings.value.styles) { _,styles in
            if !styles.contains(where:{$0.id==model.styleID}) { model.styleID=model.settings.value.selectedStyleID }
        }
        .sheet(item:$editing) { draft in
            BibleCopyStyleEditor(draft:draft,original:original,model:model,resources:resources) { editing=nil }
        }
        .confirmationDialog("¿Borrar el estilo propio «\(model.style?.name ?? "")»?",isPresented:$deleteConfirmation) {
            Button("Borrar estilo",role:.destructive) {
                guard let style=model.style else { return }
                do { try model.settings.deleteStyle(style);model.styleID=model.settings.value.selectedStyleID }
                catch { model.errorMessage=error.localizedDescription }
            }
        }
    }
    private func importStyle() {
        let panel=NSOpenPanel();panel.title="Importar estilo de copia";panel.allowsMultipleSelection=false
        panel.allowedContentTypes=[.xml,UTType(filenameExtension:"lbxcbv") ?? .data]
        panel.begin { response in
            guard response == .OK,let url=panel.url else { return }
            do {
                let access=url.startAccessingSecurityScopedResource();defer{if access { url.stopAccessingSecurityScopedResource() }}
                guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=MetadataXMLReader.maximumFileBytes else { throw PersonalStateError.tooLarge }
                let data=try Data(contentsOf:url),hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
                var style=try BibleCopyOutputStyle.importing(data,sourceSHA256:hash);style.preset=nil;style.id=UUID()
                try model.settings.saveStyle(style,replacing:nil);model.styleID=style.id
            } catch { model.errorMessage=error.localizedDescription }
        }
    }
    private func exportStyle() {
        guard let style=model.style else { return }
        do {
            let data=try style.exportedXML(),panel=NSSavePanel();panel.title="Exportar estilo de copia"
            panel.allowedContentTypes=[UTType(filenameExtension:"lbxcbv") ?? .xml];panel.nameFieldStringValue=style.name+".lbxcbv"
            panel.begin { response in
                guard response == .OK,let url=panel.url else { return }
                do { let access=url.startAccessingSecurityScopedResource();defer{if access { url.stopAccessingSecurityScopedResource() }};try data.write(to:url,options:.atomic) }
                catch { model.errorMessage=error.localizedDescription }
            }
        } catch { model.errorMessage=error.localizedDescription }
    }
}

struct BibleCopyPreviewText:NSViewRepresentable {
    let text:NSAttributedString
    final class Coordinator { var text:NSAttributedString? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.backgroundColor = .white
        let view=NSTextView();view.isEditable=false;view.isSelectable=true;view.isRichText=true;view.isHorizontallyResizable=false
        view.isVerticallyResizable=true;view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true;view.backgroundColor = .white
        view.textContainerInset=NSSize(width:18,height:18);view.setAccessibilityLabel("Texto de la vista previa de copia")
        scroll.documentView=view;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard context.coordinator.text != text,let view=scroll.documentView as? NSTextView else { return }
        view.textStorage?.setAttributedString(text);context.coordinator.text=text;view.scrollRangeToVisible(NSRange(location:0,length:0))
    }
}

struct BibleCopyStyleEditor:View {
    @ViewState private var draft:BibleCopyOutputStyle
    let original:BibleCopyOutputStyle?
    let model:BibleCopyModel
    let resources:[LibraryResource]
    let dismiss:() -> Void
    @ViewState private var source:BibleCopyDocument?
    @ViewState private var preview:NSAttributedString?
    @ViewState private var error:String?
    @ViewState private var previewError:String?
    init(draft:BibleCopyOutputStyle,original:BibleCopyOutputStyle?,model:BibleCopyModel,resources:[LibraryResource],dismiss:@escaping () -> Void) {
        _draft=State(initialValue:draft);self.original=original;self.model=model;self.resources=resources;self.dismiss=dismiss
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(original==nil ? "Nuevo estilo de copia":"Modificar estilo de copia").font(.title2)
            TextField("Nombre",text:$draft.name).textFieldStyle(.roundedBorder)
            HStack(alignment:.top,spacing:24) {
                TabView {
                    Form {
                        Toggle("Solo texto bíblico",isOn:$draft.bibleTextOnly)
                        Toggle("Formato de caracteres",isOn:$draft.characterFormatting)
                        Toggle("Formato de párrafos",isOn:$draft.paragraphFormatting)
                        Toggle("Palabras de Cristo en rojo",isOn:$draft.redLetter)
                        Toggle("Cita bibliográfica",isOn:$draft.citation)
                        Toggle("Copiar notas al pie",isOn:$draft.copyFootnotes)
                        Picker("Párrafos",selection:$draft.paragraphs) {
                            Text("Un versículo por línea").tag(BibleCopyParagraphPolicy.perVerse)
                            Text("Conservar párrafos del recurso").tag(BibleCopyParagraphPolicy.sourceParagraphs)
                            Text("Unir el pasaje").tag(BibleCopyParagraphPolicy.perPassage)
                        }.disabled(!draft.bibleTextOnly)
                    }.padding(16).tabItem{Text("Formato")}
                    ScrollView {
                        VStack(alignment:.leading,spacing:12) {
                            BibleCopyTemplateEditor(title:"Antes del pasaje",template:$draft.beforePassage)
                            BibleCopyTemplateEditor(title:"Antes del versículo",template:$draft.beforeVerse)
                            BibleCopyTemplateEditor(title:"Después del versículo",template:$draft.afterVerse)
                            BibleCopyTemplateEditor(title:"Después del pasaje",template:$draft.afterPassage)
                            Text("^a edición · ^B libro · ^b libro corto · ^c capítulo · ^n salto · ^P pasaje · ^p pasaje corto · ^R referencia · ^r referencia corta · ^v versículo · ^^ signo ^")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Formato en la plantilla: <b>, <i>, <u>, <sup> y <sub>.").font(.caption).foregroundStyle(.secondary)
                        }.padding(16)
                    }.tabItem{Text("Plantillas")}
                    Form {
                        Picker("Griego",selection:$draft.greek) {
                            Text("Unicode").tag(BibleCopyLanguageRendering.unicode);Text("Transliteración SBL").tag(BibleCopyLanguageRendering.transliterated)
                        }
                        Picker("Hebreo",selection:$draft.hebrew) {
                            Text("Unicode").tag(BibleCopyLanguageRendering.unicode);Text("Transliteración Logos").tag(BibleCopyLanguageRendering.transliterated)
                            Text("HebraicaII (pendiente)").tag(BibleCopyLanguageRendering.hebraicaII).disabled(true)
                            Text("Michigan-Claremont (pendiente)").tag(BibleCopyLanguageRendering.michiganClaremont).disabled(true)
                        }
                        Picker("Letras hebreas",selection:$draft.hebrewLetters) {
                            Text("Texto completo").tag(BibleCopyHebrewLetters.full)
                            Text("Consonantes y vocales").tag(BibleCopyHebrewLetters.consonantsAndVowels)
                            Text("Solo consonantes").tag(BibleCopyHebrewLetters.consonantsOnly)
                        }
                    }.padding(16).tabItem{Text("Idiomas")}
                }.frame(width:450)
                VStack(alignment:.leading,spacing:8) {
                    Text("Vista previa del estilo").font(.headline)
                    if let preview { BibleCopyPreviewText(text:preview) }
                    else { ContentUnavailableView("Sin vista previa",systemImage:"text.page",description:Text(previewError ?? "Preparando el pasaje…")) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer();Button("Cancelar",action:dismiss).keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    do { try model.settings.saveStyle(draft,replacing:original);model.styleID=draft.id;dismiss() }
                    catch { self.error=error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:940,height:660)
        .task {
            do {
                guard let resource=resources.first(where:{$0.id==model.resourceID}) else { throw BibleCopyError.missingBoundary }
                source=try await BibleCopyService().prepare(resource,passage:.parse(model.passage),abbreviation:resource.location.deletingPathExtension().lastPathComponent)
                try Task.checkCancellation();refreshPreview()
            } catch is CancellationError {} catch { previewError=error.localizedDescription }
        }
        .onChange(of:draft){_,_ in refreshPreview()}
        .onChange(of:draft.paragraphs) { _,policy in
            if policy == .perVerse && !draft.afterVerse.pattern.contains("^n") { draft.afterVerse.pattern += "^n" }
            if policy == .perPassage { draft.afterVerse.pattern=draft.afterVerse.pattern.replacingOccurrences(of:"^n",with:"") }
        }
        .onChange(of:draft.afterVerse.pattern) { _,pattern in
            if draft.paragraphs != .sourceParagraphs { draft.paragraphs=pattern.contains("^n") ? .perVerse:.perPassage }
        }
    }
    private func refreshPreview() {
        guard let source else { return }
        do { preview=try NativeBibleCopyOutput.prepare(BibleCopyFormatter.format(source,style:draft,referenceLanguage:model.referenceLanguage)).preview;previewError=nil }
        catch { preview=nil;previewError=error.localizedDescription }
    }
}

struct BibleCopyTemplateEditor:View {
    let title:String
    @Binding var template:BibleCopyOutputTemplate
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.headline)
            TextField(title,text:$template.pattern,axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            HStack {
                Toggle("N",isOn:$template.bold).help("Negrita").accessibilityLabel("\(title): negrita")
                Toggle("I",isOn:$template.italic).help("Cursiva").accessibilityLabel("\(title): cursiva")
                Toggle("S",isOn:$template.underline).help("Subrayado").accessibilityLabel("\(title): subrayado")
                Toggle("Super",isOn:$template.superscript).accessibilityLabel("\(title): superíndice")
                Toggle("Sub",isOn:$template.subscriptText).accessibilityLabel("\(title): subíndice")
            }.toggleStyle(.button).font(.caption)
        }
    }
}
