import AppKit
import LibronixCore
import LibronixOutputMac
import Observation

@MainActor @Observable final class BibleCopySettingsStore {
    private(set) var value=BibleCopyPersonalState()
    var errorMessage:String?
    @ObservationIgnored private let file:PersonalStateFile<BibleCopyPersonalState>
    private var writable=false
    init(directory:URL? = nil) {
        let root=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Libron-X")
        file=PersonalStateFile(url:root.appendingPathComponent("bible-copy.json"))
        do { if let candidate=try file.load() { try candidate.validate();value=candidate };writable=true }
        catch { errorMessage=error.localizedDescription }
    }
    func change(_ action:(inout BibleCopyPersonalState) throws -> Void) throws {
        guard writable else { throw PersonalStateError.invalid("Las opciones de copia guardadas necesitan una versión compatible antes de editarse.") }
        var candidate=value;try action(&candidate);try candidate.validate()
        guard candidate != value else { return };try file.save(candidate);value=candidate
    }
    func saveStyle(_ candidate:BibleCopyOutputStyle,replacing original:BibleCopyOutputStyle?) throws {
        guard candidate.preset==nil else { throw BibleCopyError.invalidStyle };try candidate.validate()
        try change { state in
            if let original {
                guard candidate.id==original.id,let index=state.customStyles.firstIndex(where:{$0.id==original.id}),state.customStyles[index]==original else { throw PersonalStateError.concurrentChange }
                state.customStyles[index]=candidate
            } else {
                guard !state.styles.contains(where:{$0.id==candidate.id}) else { throw BibleCopyError.invalidStyle }
                state.customStyles.append(candidate)
            }
            state.selectedStyleID=candidate.id
        }
    }
    func deleteStyle(_ original:BibleCopyOutputStyle) throws {
        try change { state in
            guard let index=state.customStyles.firstIndex(where:{$0==original}) else { throw PersonalStateError.concurrentChange }
            state.customStyles.remove(at:index)
            if state.selectedStyleID==original.id { state.selectedStyleID=BibleCopyOutputStyle.defaults[1].id }
        }
    }
}

@MainActor @Observable final class BibleCopyModel {
    let settings:BibleCopySettingsStore
    var isPresented=false
    var passage="" { didSet { if passage != oldValue { invalidate() } } }
    var resourceID:String? { didSet { if resourceID != oldValue { invalidate() } } }
    var styleID=BibleCopyOutputStyle.defaults[1].id { didSet { if styleID != oldValue { invalidate() } } }
    var referenceLanguage=BibleCopyReferenceLanguage.english { didSet { if referenceLanguage != oldValue { invalidate() } } }
    var keepOpen=false
    private(set) var payload:NativeBibleCopyPayload?
    private(set) var document:BibleCopyDocument?
    private(set) var renderedReferenceLanguage:BibleCopyReferenceLanguage?
    private(set) var isPreparing=false
    var errorMessage:String?
    var message:String?
    @ObservationIgnored private let service=BibleCopyService()
    @ObservationIgnored private var task:Task<Void,Never>?
    @ObservationIgnored private var generation=0
    init(settings:BibleCopySettingsStore) { self.settings=settings;restoreFields() }
    var style:BibleCopyOutputStyle? { settings.value.styles.first{$0.id==styleID} }
    var canCopy:Bool {
        !isPreparing && payload?.text.isEmpty == false && payload?.document.style==style &&
        document?.passage.original==passage && document?.resourceID==resourceID && renderedReferenceLanguage==referenceLanguage
    }
    func restoreFields() {
        let value=settings.value;passage=value.passage;resourceID=value.resourceID;styleID=value.selectedStyleID;keepOpen=value.keepOpen;referenceLanguage=value.referenceLanguage
    }
    func open(resources:[LibraryResource],current:LibraryResource?,reference:String?) {
        invalidate();restoreFields();errorMessage=settings.errorMessage
        if resourceID==nil || !resources.contains(where:{$0.id==resourceID}) {
            resourceID=current?.format == .legacyLSF ? current?.id:resources.first(where:{$0.format == .legacyLSF && !$0.isHelp})?.id
        }
        if let reference,LegacyPassageQuery.parse(reference) != nil { passage=reference }
        isPresented=true
    }
    func invalidate() { task?.cancel();task=nil;generation += 1;isPreparing=false;payload=nil;document=nil;renderedReferenceLanguage=nil;message=nil;errorMessage=nil }
    func prepare(resources:[LibraryResource]) {
        invalidate()
        do {
            let query=try BibleCopyPassage.parse(passage)
            guard let resource=resources.first(where:{$0.id==resourceID}),let style else { throw BibleCopyError.missingBoundary }
            let token=generation,language=referenceLanguage
            isPreparing=true
            task=Task { [weak self,service] in
                do {
                    let abbreviation=resource.location.deletingPathExtension().lastPathComponent
                    let document=try await service.prepare(resource,passage:query,abbreviation:abbreviation,includeFootnotes:style.copyFootnotes)
                    let formatted=try BibleCopyFormatter.format(document,style:style,referenceLanguage:language)
                    try Task.checkCancellation();guard let self,self.generation==token else { return }
                    let payload=try NativeBibleCopyOutput.prepare(formatted)
                    try Task.checkCancellation();guard self.generation==token else { return }
                    self.document=document;self.payload=payload;self.renderedReferenceLanguage=language;self.isPreparing=false;self.task=nil
                    if !document.hasVerseText { self.message="El pasaje no contiene versículos en esta edición.\(style.citation ? " La salida contiene la cita bibliográfica.":"")" }
                } catch is CancellationError {} catch {
                    guard let self,self.generation==token else { return };self.errorMessage=error.localizedDescription;self.isPreparing=false;self.task=nil
                }
            }
        } catch { errorMessage=error.localizedDescription }
    }
    func persistFields() throws {
        try settings.change{$0.passage=passage;$0.resourceID=resourceID;$0.selectedStyleID=styleID;$0.keepOpen=keepOpen;$0.referenceLanguage=referenceLanguage}
    }
    func copy(to pasteboard:NSPasteboard = .general) {
        guard canCopy,let payload else { return }
        do {
            try persistFields();try NativeBibleCopyOutput.copy(payload,to:pasteboard)
            message="Copiado: \(document?.verses.count ?? 0) versículos, texto Unicode y formato enriquecido."
            if !keepOpen { isPresented=false }
        } catch { errorMessage=error.localizedDescription }
    }
    func close() {
        do { try persistFields();invalidate();isPresented=false }
        catch { errorMessage=error.localizedDescription }
    }
}
