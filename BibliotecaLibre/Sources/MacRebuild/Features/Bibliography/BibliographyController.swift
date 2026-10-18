import Foundation
import Observation
import LibronixCore

struct BibliographyContext: Equatable, Sendable {
    var resources:[LibraryResource]
    var collections:[LibraryCollection]
    var collectionsError:String?
}
enum BibliographyScopeError: Error { case emptySelection, emptyCollections }
@MainActor @Observable final class BibliographyController {
    typealias Generate = @Sendable ([LibraryResource],BibliographyScope) async throws -> BibliographyReport
    var kind=BibliographyScope.Kind.library { didSet { if oldValue != kind { cancel() } } }
    var collectionIDs:Set<UUID>=[] { didSet { if oldValue != collectionIDs { cancel() } } }
    private(set) var selected:[String:LibraryCollectionMember]=[:] { didSet { if oldValue != selected { cancel() } } }
    var order=BibliographyOrder.authorTitle { didSet { if let report { self.report=report.ordered(by:order) } } }
    private(set) var report:BibliographyReport?
    private(set) var isLoading=false
    private(set) var error:String?
    private(set) var revision=0
    var selectedResultID:String?
    var canExport:Bool { report != nil && !isLoading && completedRequest == request }
    var configurationChanged:Bool { report != nil && completedRequest != request }
    @ObservationIgnored private var context=BibliographyContext(resources:[],collections:[],collectionsError:nil)
    @ObservationIgnored private var generation=0
    @ObservationIgnored private var task:Task<Void,Never>?
    @ObservationIgnored private var completedRequest:Request?
    @ObservationIgnored private let generate:Generate
    private struct Request:Equatable {
        let revision:Int;let kind:BibliographyScope.Kind;let collections:Set<UUID>;let selected:[String:LibraryCollectionMember]
    }
    private var request:Request { .init(revision:revision,kind:kind,collections:kind == .collections ? collectionIDs : [],selected:kind == .selection ? selected : [:]) }
    init(generate:@escaping Generate = { resources,scope in
        let job=Task.detached { try BibliographyReportGenerator.generate(resources:resources,scope:scope) }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }) { self.generate=generate }
    func updateContext(_ next:BibliographyContext) {
        guard next != context else { return };cancel();context=next;revision += 1
    }
    func select(_ resources:[LibraryResource]) {
        var next=selected;for resource in resources { next[resource.id] = .init(resource) };selected=next
    }
    func setSelection(_ ids:Set<String>) {
        var next=selected.filter { ids.contains($0.key) }
        for resource in context.resources where ids.contains(resource.id) && next[resource.id] == nil { next[resource.id] = .init(resource) }
        selected=next
    }
    func clearSelection() { selected=[:] }
    func cancel() { generation += 1;task?.cancel();task=nil;isLoading=false;error=nil }
    func run() {
        cancel();let token=generation,submitted=request
        do {
            let resolved=try Self.resolve(kind:kind,collections:collectionIDs,selected:selected,context:context)
            isLoading=true
            task=Task { [weak self,generate] in
                do {
                    let result=try await generate(resolved.0,resolved.1)
                    try Task.checkCancellation()
                    guard let self,self.generation == token,self.request == submitted else { return }
                    self.report=result.ordered(by:self.order);self.completedRequest=submitted
                    if !result.entries.contains(where:{ $0.id == self.selectedResultID }) { self.selectedResultID=result.entries.first?.id }
                    self.isLoading=false;self.task=nil
                } catch {
                    guard let self,self.generation == token else { return };self.isLoading=false;self.task=nil
                    if !(error is CancellationError) { self.error=Self.message(error) }
                }
            }
        } catch { self.error=Self.message(error) }
    }
    static func resolve(kind:BibliographyScope.Kind,collections:Set<UUID>,selected:[String:LibraryCollectionMember],context:BibliographyContext) throws -> ([LibraryResource],BibliographyScope) {
        guard Set(context.resources.map(\.id)).count == context.resources.count else { throw BibliographyReportError.duplicateIdentity }
        let pool=Dictionary(uniqueKeysWithValues:context.resources.map { ($0.id,$0) })
        if kind == .library { return (context.resources,.init(kind:kind,names:[],requestedCount:context.resources.count)) }
        var members:[LibraryCollectionMember]=[],names:[String]=[],issues:[BibliographyScopeIssue]=[]
        if kind == .selection {
            guard !selected.isEmpty else { throw BibliographyScopeError.emptySelection }
            members=selected.keys.sorted().compactMap { selected[$0] }
        } else {
            guard !collections.isEmpty else { throw BibliographyScopeError.emptyCollections }
            if let error=context.collectionsError { throw PersonalStateError.invalid(error) }
            guard Set(context.collections.map(\.id)).count == context.collections.count else { throw BibliographyReportError.duplicateIdentity }
            for id in collections.sorted(by:{ $0.uuidString < $1.uuidString }) {
                guard let collection=context.collections.first(where:{ $0.id == id }) else {
                    issues.append(.init(identity:id.uuidString,title:id.uuidString,reason:.missingCollection));continue
                }
                if let rule=collection.rule { try rule.validate() }
                names.append(collection.name);members += collection.resolvedMembers(in:context.resources)
            }
        }
        var unique:[String:LibraryCollectionMember]=[:]
        for member in members {
            if let previous=unique[member.id],previous.format != member.format || previous.legacyIdentifier != member.legacyIdentifier { throw BibliographyReportError.duplicateIdentity }
            unique[member.id]=member
        }
        var resources:[LibraryResource]=[]
        for member in unique.values.sorted(by:{ $0.id < $1.id }) {
            guard let current=pool[member.id] else { issues.append(.init(identity:member.id,title:member.title,reason:.missingResource));continue }
            guard member.resolve(in:[current]) != nil else { issues.append(.init(identity:member.id,title:member.title,reason:.changedIdentity));continue }
            resources.append(current)
        }
        return (resources,.init(kind:kind,names:names,requestedCount:unique.count,issues:issues,identities:kind == .collections ? collections.map(\.uuidString).sorted() : selected.keys.sorted()))
    }
    private static func message(_ error:any Error) -> String {
        switch error {
        case BibliographyScopeError.emptySelection:return L("Selecciona recursos para la bibliografía.")
        case BibliographyScopeError.emptyCollections:return L("Selecciona una colección para la bibliografía.")
        case BibliographyReportError.tooManyResources:return L("La bibliografía supera el límite de recursos.")
        case BibliographyReportError.duplicateIdentity:return L("La bibliografía contiene identidades de recurso incompatibles.")
        case BibliographyReportError.unsafeMetadata:return L("Los metadatos superan los límites del informe o contienen datos inválidos.")
        case BibliographyReportError.invalidScope:return L("El ámbito de la bibliografía no es válido.")
        default:return error.localizedDescription
        }
    }
    deinit { task?.cancel() }
}
