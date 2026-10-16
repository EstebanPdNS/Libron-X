import LibronixCore
import SwiftUI

struct ResourceWorkspace: View {
    let resource: LibraryResource
    @Bindable var reader: ResourceReaderModel
    @Binding var linkGroup: ReaderLinkGroup
    var annotations: [ReaderAnnotation] = []
    var openAnnotation: ((ReaderAnnotation) -> Void)?
    let reveal: () -> Void
    @AppStorage("readerFontSize.v1") private var fontSize = 18.0
    @AppStorage("readerFontFamily.v1") private var fontFamily = "serif"
    @FocusState private var locatorIsFocused: Bool
    @FocusState private var findIsFocused: Bool
    @ViewState private var showsFind = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Presentación del recurso", selection: $reader.tab) {
                    ForEach(ReaderTab.allCases) { tab in Text(tab.title).tag(tab) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                Picker("Vínculo entre lectores", selection: $linkGroup) {
                    ForEach(ReaderLinkGroup.allCases, id: \.self) { group in Text(group.title).tag(group) }
                }.frame(width: 135).controlSize(.small)
                    .disabled(resource.format != .legacyLSF)
                if reader.tab == .preview, resource.format == .legacyLSF {
                    Button { reader.showsContents.toggle() } label: { Image(systemName: "list.bullet") }
                        .help("Contenido del recurso").accessibilityLabel("Contenido del recurso")
                        .disabled(reader.directory == nil)
                        .popover(isPresented: $reader.showsContents) { contents }
                    Menu {
                        ForEach([14.0, 16, 18, 20, 24, 28], id: \.self) { size in Button("\(Int(size)) pt") { fontSize = size } }
                    } label: { Image(systemName: "textformat.size") }
                    .help("Tamaño del texto").accessibilityLabel("Tamaño del texto")
                }
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if reader.tab == .information { ResourceOverview(resource: resource, reveal: reveal) }
            else { contentPreview }
        }
        .task(id: resource.id) { reader.open(resource) }
        .onChange(of: reader.findFocusRequest) { _, _ in showsFind = true; findIsFocused = true }
        .onChange(of: reader.locatorFocusRequest) { _, _ in locatorIsFocused = true }
    }
    private var contentPreview: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(resource.title).font(.system(size: 22, weight: .medium, design: .serif)).lineLimit(2)
                if resource.format == .legacyLSF {
                    HStack(spacing: 8) {
                        Button(action: reader.goBack) { Image(systemName: "arrow.left") }
                            .disabled(!reader.canGoBack).help("Atrás · ⌘[").accessibilityLabel("Atrás")
                        Button(action: reader.goForward) { Image(systemName: "arrow.right") }
                            .disabled(!reader.canGoForward).help("Adelante · ⌘]").accessibilityLabel("Adelante")
                        TextField("Pasaje o posición · Génesis 1:1", text: $reader.locatorInput)
                            .textFieldStyle(.roundedBorder).focused($locatorIsFocused).onSubmit(reader.submitLocator)
                            .disabled(reader.isLoading).accessibilityLabel("Ir a un pasaje o posición")
                        Button("Ir", action: reader.submitLocator).disabled(reader.isLoading || reader.locatorInput.isEmpty)
                    }
                    HStack(spacing: 8) {
                        Button { reader.load(reader.ordinal - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(reader.ordinal == 0 || reader.isLoading).help("Artículo anterior").accessibilityLabel("Artículo anterior")
                        TextField("Número de artículo", text: $reader.sectionInput)
                            .textFieldStyle(.roundedBorder).frame(width: 65).onSubmit(reader.submitSection).disabled(reader.isLoading)
                        Text("/ \(reader.sections.count)").font(.caption).foregroundStyle(.secondary)
                        Button { reader.load(reader.ordinal + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(reader.ordinal + 1 >= reader.sections.count || reader.isLoading)
                            .help("Artículo siguiente").accessibilityLabel("Artículo siguiente")
                        Spacer()
                        if !annotations.isEmpty {
                            Menu {
                                ForEach(annotations) { annotation in Button(annotation.title) { openAnnotation?(annotation) } }
                            } label: { Label("\(annotations.count)", systemImage: "note.text") }
                                .help("Notas vinculadas a este artículo").accessibilityLabel("Notas vinculadas a este artículo")
                        }
                        Button(action: reader.toggleBookmark) { Image(systemName: reader.isBookmarked ? "bookmark.fill" : "bookmark") }
                            .disabled(reader.content == nil).help("Guardar esta posición")
                            .accessibilityLabel(reader.isBookmarked ? "Quitar marcador" : "Guardar marcador")
                        Button { showsFind.toggle(); findIsFocused = showsFind } label: { Image(systemName: "magnifyingglass") }
                            .disabled(reader.content == nil).help("Buscar en el artículo · ⌘F").accessibilityLabel("Buscar en el artículo")
                    }
                    Text(reader.currentTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let message = reader.navigationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.bordered)
            Divider()
            if showsFind {
                HStack(spacing: 10) {
                    TextField("Buscar en este artículo", text: $reader.findText).textFieldStyle(.roundedBorder)
                        .focused($findIsFocused).onSubmit(reader.findNext)
                        .onChange(of: reader.findText) { _, _ in reader.findFromBeginning() }
                    Button("Anterior", action: reader.findPrevious)
                    Button("Siguiente", action: reader.findNext)
                    Button { showsFind = false; reader.highlightRange = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Cerrar búsqueda")
                }.padding(12)
                if let message = reader.findMessage { Text(message).font(.caption).foregroundStyle(.red).padding(.bottom, 8) }
                Divider()
            }
            if let content = reader.content, resource.format == .legacyLSF {
                ReaderTextView(text: content.plainText, fontSize: fontSize, fontFamily: fontFamily, highlightRange: reader.highlightRange,
                               graphics: reader.graphicAssets, tables: content.tables, annotations: annotations, selectionChanged: reader.recordSelection)
                    .overlay { if reader.isLoading { ProgressView("Abriendo el artículo…").padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
                compatibilityFooter(content)
            } else if reader.isLoading {
                ProgressView("Abriendo el recurso…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Este contenido aún no está disponible", systemImage: "book.closed",
                    description: Text("El recurso necesita compatibilidad adicional para representarlo fielmente."))
                if let message = reader.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(24) }
            }
        }.background(LibraryPalette.paper)
    }
    private func compatibilityFooter(_ content: LegacySectionContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label("Texto recuperado · presentación parcial", systemImage: "info.circle").font(.caption.weight(.medium))
            Text("Los estilos completos, zonas activas y enlaces del original continúan en desarrollo.").font(.caption2).foregroundStyle(.secondary)
            if !content.graphics.isEmpty {
                Text("\(reader.graphicAssets.count) de \(content.graphics.count) imágenes disponibles en este artículo.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !content.tables.isEmpty {
                Text("\(content.tables.count) tablas recuperadas · estilos y combinaciones de celdas en revisión.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !content.warnings.isEmpty || !reader.graphicWarnings.isEmpty || reader.errorMessage != nil || reader.directoryWarning != nil {
                DisclosureGroup("Detalles de compatibilidad") {
                    ForEach(Array(content.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption2) }
                    ForEach(Array(reader.graphicWarnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption2) }
                    if let message = reader.errorMessage { Text(message).font(.caption2) }
                    if let message = reader.directoryWarning { Text(message).font(.caption2) }
                }.font(.caption).textSelection(.enabled)
            }
        }.padding(.horizontal, 24).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var contents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contenido").font(.title3.weight(.semibold))
            TextField("Filtrar artículos", text: $reader.articleFilter).textFieldStyle(.roundedBorder)
            if !reader.savedBookmarks.isEmpty {
                Menu("Marcadores") {
                    ForEach(reader.savedBookmarks, id: \.self) { ordinal in
                        Button(reader.directory?.entries.first(where: { $0.sectionOrdinal == ordinal && $0.title != nil })?.displayTitle ?? "Artículo \(ordinal + 1)") {
                            reader.load(ordinal); reader.showsContents = false
                        }
                    }
                }
            }
            List(reader.visibleEntries) { entry in
                Button { reader.openEntry(entry); reader.showsContents = false } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.displayTitle).lineLimit(2)
                        if let label = entry.positionLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.buttonStyle(.plain)
            }.listStyle(.inset)
        }.padding(18).frame(width: 340, height: 560)
    }
}
