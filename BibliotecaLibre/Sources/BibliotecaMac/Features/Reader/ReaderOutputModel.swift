import AppKit
import LibronixCore
import LibronixOutputMac
import Observation
import PDFKit
import UniformTypeIdentifiers

@MainActor @Observable final class ReaderOutputSettingsStore {
    private(set) var value = ReaderPrintSettings()
    var errorMessage: String?
    private var writable = false
    @ObservationIgnored private let file: PersonalStateFile<ReaderPrintSettings>
    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Libron-X")
        file = PersonalStateFile(url:root.appendingPathComponent("print-settings.json"))
        do { if let value = try file.load() { try value.validate(); self.value = value }; writable = true }
        catch { errorMessage = error.localizedDescription }
    }
    func save(_ candidate: ReaderPrintSettings) throws {
        guard writable else { throw PersonalStateError.invalid("Las opciones guardadas necesitan una versión compatible antes de editarse.") }
        try candidate.validate(); try file.save(candidate); value = candidate
    }
}
enum ReaderOutputAction { case preview, export, printReading, printSelection, previewSelection }
enum ReaderOutputFormat: String, CaseIterable { case html, text, pdf, rtf
    var title: String { switch self { case .html:"HTML";case .text:"Texto";case .pdf:"PDF";case .rtf:"Texto enriquecido (RTF)" } }
    var extensionName: String { self == .text ? "txt" : rawValue }
    var type: UTType { switch self { case .html:.html;case .text:.plainText;case .pdf:.pdf;case .rtf:.rtf } }
}

@MainActor @Observable final class ReaderOutputModel {
    let settings: ReaderOutputSettingsStore
    private(set) var document: ReaderOutputDocument?
    private(set) var pdfData: Data?
    private(set) var renderedSettings: ReaderPrintSettings?
    var showsPreview = false
    var showsPageSetup = false
    var isPreparing = false
    var errorMessage: String?
    @ObservationIgnored private let service = ReaderOutputService()
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var generation = 0
    init(settings: ReaderOutputSettingsStore) { self.settings = settings }
    func cancelPreparation() { task?.cancel(); task = nil; generation += 1; isPreparing = false }
    func prepare(resource: LibraryResource, location: ReaderLocation, selection: SearchTextRange?, action: ReaderOutputAction, window: NSWindow?) {
        cancelPreparation(); errorMessage = nil
        guard let fingerprint = location.textFingerprint else { errorMessage = "La lectura todavía no tiene un texto confirmado."; return }
        let request: ReaderOutputRequest
        if action == .printSelection || action == .previewSelection {
            guard let selection, selection.length > 0 else { return }; request = .selection(selection)
        } else { request = .reading }
        let token = generation; isPreparing = true
        task = Task { [weak self,service] in
            do {
                let document = try await service.prepare(resource,sectionOrdinal:location.sectionOrdinal,expectedTextFingerprint:fingerprint,request:request)
                try Task.checkCancellation(); guard let self, self.generation == token else { return }
                let pdf = try NativeReaderOutput.pdf(document,settings:self.settings.value)
                try Task.checkCancellation(); guard self.generation == token else { return }
                self.document = document; self.pdfData = pdf; self.renderedSettings = self.settings.value
                self.isPreparing = false; self.task = nil
                switch action {
                case .preview,.previewSelection: self.showsPreview = true
                case .export: self.export(.html)
                case .printReading,.printSelection: self.printDocument(window:window)
                }
            } catch is CancellationError { }
            catch { guard let self,self.generation == token else { return }; self.errorMessage = error.localizedDescription; self.isPreparing = false; self.task = nil }
        }
    }
    func applySettings(_ candidate: ReaderPrintSettings) throws {
        let prepared = try document.map { try NativeReaderOutput.pdf($0,settings:candidate) }
        try settings.save(candidate)
        if let prepared { pdfData = prepared; renderedSettings = candidate }
    }
    func refreshPreview() {
        guard let document, renderedSettings != settings.value else { return }
        do { pdfData = try NativeReaderOutput.pdf(document,settings:settings.value); renderedSettings = settings.value }
        catch { errorMessage = error.localizedDescription }
    }
    func data(_ format: ReaderOutputFormat) throws -> Data {
        guard let document else { throw ReaderOutputError.invalidSelection }
        switch format {
        case .html: return try ReaderOutputEncoder.html(document)
        case .text: return ReaderOutputEncoder.text(document)
        case .rtf: return try NativeReaderOutput.rtf(document,fontSize:settings.value.fontSize,includeCitation:true)
        case .pdf:
            refreshPreview(); guard renderedSettings == settings.value, let pdfData else { throw ReaderOutputError.invalidSelection }; return pdfData
        }
    }
    func export(_ format: ReaderOutputFormat) {
        guard let document else { return }
        do {
            let bytes = try data(format), panel = NSSavePanel()
            panel.title = "Exportar \(document.scopeLabel)"; panel.allowedContentTypes = [format.type]
            panel.nameFieldStringValue = document.scopeLabel.replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-") + "." + format.extensionName
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try bytes.write(to:url,options:.atomic)
                } catch { self?.errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func printDocument(window: NSWindow?) {
        do {
            let bytes = try data(.pdf)
            guard let document = PDFDocument(data:bytes) else { throw ReaderOutputError.invalidSelection }
            guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { throw ReaderOutputError.invalidSelection }
            info.paperSize = NSSize(width:settings.value.width,height:settings.value.height)
            info.leftMargin = 0; info.rightMargin = 0; info.topMargin = 0; info.bottomMargin = 0
            guard let operation = document.printOperation(for:info,scalingMode:.pageScaleDownToFit,autoRotate:false) else { throw ReaderOutputError.invalidSelection }
            operation.showsPrintPanel = true; operation.showsProgressPanel = true
            // SwiftUI preview is a sheet. Printing on its parent queues the
            // print panel until that preview closes; present on the visible sheet.
            if let presentingWindow = window?.attachedSheet ?? window ?? NSApp.keyWindow {
                operation.runModal(for:presentingWindow,delegate:nil,didRun:nil,contextInfo:nil)
            }
            else { operation.run() }
        } catch { errorMessage = error.localizedDescription }
    }
}
