import AppKit
import LibronixCore
import PDFKit
import SwiftUI

struct ReaderOutputPreview: View {
    @Bindable var output: ReaderOutputModel
    let window: NSWindow?
    @ViewState private var scale = "width"
    var body: some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("Vista previa de impresión").font(.title2)
                    Text([output.document?.title,output.document?.scopeLabel].compactMap{$0}.joined(separator:" · ")).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Escala de vista previa",selection:$scale) {
                    Text("Ancho de página").tag("width"); Text("Página completa").tag("page"); Text("Dos páginas").tag("two")
                    ForEach([10,25,50,75,100,150,200,500],id:\.self) { Text("\($0)%").tag(String($0)) }
                }.labelsHidden().accessibilityLabel("Escala de vista previa").frame(width:180)
                Button("Configurar página…") { output.showsPageSetup = true }
            }.padding(18)
            Divider()
            if let data = output.pdfData { ReaderPDFPreview(data:data,scale:scale).frame(maxWidth:.infinity,maxHeight:.infinity) }
            HStack {
                Text(output.document?.scope == .selection ? "Solo la selección, con cita bibliográfica." : "\(output.document?.references.count ?? 0) referencias · salida completa del ámbito mostrado.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Guardar…") { ForEach(ReaderOutputFormat.allCases,id:\.self) { format in Button(format.title) { output.export(format) } } }
                Button("Imprimir…") { output.printDocument(window:window) }
                Button("Cerrar") { output.showsPreview = false }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }.frame(minWidth:780,minHeight:620)
        .onChange(of:output.settings.value) { _,_ in output.refreshPreview() }
        .sheet(isPresented:$output.showsPageSetup) { ReaderPageSetup(output:output) }
    }
}

struct ReaderPDFPreview: NSViewRepresentable {
    let data: Data
    let scale: String
    final class Coordinator { var data: Data?; var scale = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> PDFView {
        let view = PDFView(); view.backgroundColor = .controlBackgroundColor
        view.minScaleFactor = 0.1; view.maxScaleFactor = 5
        view.setAccessibilityLabel("Páginas de la vista previa")
        return view
    }
    func updateNSView(_ view:PDFView,context:Context) {
        let changed = context.coordinator.data != data
        if changed {
            let page = view.currentPage.flatMap { view.document?.index(for:$0) } ?? 0
            view.document = PDFDocument(data:data)
            if let destination = view.document?.page(at:min(page,max(0,(view.document?.pageCount ?? 1)-1))) { view.go(to:destination) }
            context.coordinator.data = data
        }
        if changed || context.coordinator.scale != scale {
            view.displayMode = scale == "two" ? .twoUp : scale == "page" ? .singlePage : .singlePageContinuous
            view.autoScales = Int(scale) == nil
            if let percent = Int(scale) { view.scaleFactor = Double(percent)/100 }
            context.coordinator.scale = scale
        }
    }
}

struct ReaderPageSetup: View {
    @Bindable var output: ReaderOutputModel
    @ViewState private var draft: ReaderPrintSettings
    @ViewState private var error: String?
    init(output:ReaderOutputModel) { self.output = output; _draft = State(initialValue:output.settings.value) }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Configurar página").font(.title2)
            Form {
                Picker("Papel",selection:$draft.paper) { Text("A4").tag(ReaderPaper.a4); Text("Carta").tag(ReaderPaper.letter) }
                Toggle("Orientación horizontal",isOn:$draft.landscape)
                TextField("Letra (pt)",value:$draft.fontSize,format:.number)
                Section("Márgenes (pt)") {
                    TextField("Izquierdo",value:$draft.leftMargin,format:.number)
                    TextField("Derecho",value:$draft.rightMargin,format:.number)
                    TextField("Superior",value:$draft.topMargin,format:.number)
                    TextField("Inferior",value:$draft.bottomMargin,format:.number)
                }
                Toggle("Numerar páginas",isOn:$draft.pageNumbers)
                Toggle("Mostrar título en cabecera",isOn:$draft.showTitle)
                Toggle("Pie con Libron-X y fecha",isOn:$draft.footer)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancelar") { output.showsPageSetup = false }.keyboardShortcut(.cancelAction)
                Button("Aplicar") {
                    do { try output.applySettings(draft); output.showsPageSetup = false }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:410)
    }
}
